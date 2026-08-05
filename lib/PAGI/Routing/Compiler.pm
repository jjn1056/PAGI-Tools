package PAGI::Routing::Compiler;

use strict;
use warnings;
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed refaddr);
use PAGI::Context;
use PAGI::Routing::Middleware ();
use PAGI::Utils ();

sub compile {
    my ($class, $description) = @_;

    croak 'routing description is required'
        unless blessed($description);

    if ($description->isa('PAGI::Routing::Route')
            || $description->isa('PAGI::Routing::Mount')) {
        require PAGI::Routing::Router;
        $description = PAGI::Routing::Router->new(routes => [$description]);
    }

    croak 'unsupported routing description'
        unless $description->isa('PAGI::Routing::Router');

    return $class->_compile_http_router($description);
}

sub _compile_http_router {
    my ($class, $router) = @_;

    my @compiled_entries;
    for my $node (@{$router->routes}) {
        next unless $node->isa('PAGI::Routing::Route')
            && $node->kind eq 'route';
        push @compiled_entries, {
            route => $node,
            app => $class->_compile_http_leaf($node),
        };
    }

    my $not_found_handler = $router->not_found || sub {
        my ($context) = @_;
        return $context->text('Not Found');
    };
    my $method_not_allowed_handler = $router->method_not_allowed || sub {
        my ($context) = @_;
        return $context->text('Method Not Allowed');
    };
    my $not_found = $class->_compile_generated_handler(
        $not_found_handler,
        404,
    );
    my $method_not_allowed = $class->_compile_generated_handler(
        $method_not_allowed_handler,
        405,
    );

    my $dispatcher = async sub {
        my ($scope, $receive, $send) = @_;
        my $decision = $class->_select_http(\@compiled_entries, $scope);

        if ($decision->{kind} eq 'full') {
            await $decision->{app}->($decision->{scope}, $receive, $send);
            return;
        }

        if ($decision->{kind} eq 'partial') {
            my $allow = join ', ', @{$decision->{allowed_methods}};
            my $provenance = {};
            my $generated_send = $class->_generated_allow_send(
                $send,
                $allow,
                $provenance,
            );
            await $method_not_allowed->(
                $scope,
                $receive,
                $generated_send,
                $allow,
                $provenance,
            );
            return;
        }

        await $not_found->($scope, $receive, $send);
        return;
    };

    my $app = PAGI::Routing::Middleware->_wrap_descriptors(
        $router->middleware,
        $dispatcher,
    );

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $is_head = ($scope->{type} // '') eq 'http'
            && ($scope->{method} // '') eq 'HEAD';
        my $wire_send = $is_head
            ? $class->_head_wire_send($send)
            : $send;

        await $app->($scope, $receive, $wire_send);
        return;
    };
}

sub _head_wire_send {
    my ($class, $send) = @_;
    my $terminal_sent = 0;

    return sub {
        my ($event) = @_;
        my $type = $event->{type} // '';

        return Future->done
            if $type eq 'http.response.trailers';

        if ($type eq 'http.response.body') {
            return Future->done
                if $terminal_sent || $event->{more};

            $terminal_sent = 1;
            return $send->({
                type => 'http.response.body',
                body => '',
                more => 0,
            });
        }

        return $send->($event);
    };
}

sub _compile_http_leaf {
    my ($class, $route) = @_;

    my $app;
    if ($route->is_raw) {
        my $raw_app = PAGI::Utils::to_app($route->target);
        $app = async sub {
            my ($scope, $receive, $send) = @_;
            my $returned = $raw_app->($scope, $receive, $send);
            await Future->wrap($returned);
            return;
        };
    }
    else {
        $app = $class->_compile_http_handler($route->target);
    }

    return PAGI::Routing::Middleware->_wrap_descriptors(
        $route->middleware,
        $app,
    );
}

sub _compile_http_handler {
    my ($class, $handler, $policy) = @_;

    return async sub {
        my ($scope, $receive, $send, @policy_arguments) = @_;
        my $context = PAGI::Context->new($scope, $receive, $send);
        my $policy_state = $policy
            ? $policy->{before}->($context, @policy_arguments)
            : undef;
        my $returned = $handler->($context);
        my $result = await Future->wrap($returned);

        croak 'handler did not return a response'
            unless PAGI::Utils::is_response($result);

        $policy->{after}->($result, $policy_state) if $policy;
        await $context->respond($result);
        return;
    };
}

sub _compile_generated_handler {
    my ($class, $handler, $status) = @_;

    my $policy = {
        before => sub {
            my ($context, $allow, $provenance) = @_;
            $provenance ||= {};
            my $seeded = $context->response->status($status);
            $seeded->header('Allow' => $allow)
                if $status == 405 && defined $allow;
            $provenance->{seed_identity} = refaddr($seeded);
            return $provenance;
        },
        after => sub {
            my ($result, $state) = @_;
            $state->{returned_seed} = refaddr($result) == $state->{seed_identity}
                ? 1
                : 0;
        },
    };

    return $class->_compile_http_handler($handler, $policy);
}

sub _generated_allow_send {
    my ($class, $send, $allow, $provenance) = @_;

    return sub {
        my ($event) = @_;
        return $send->($event)
            unless ($event->{type} // '') eq 'http.response.start';

        my $headers = ref($event->{headers}) eq 'ARRAY'
            ? $event->{headers}
            : [];

        if (($event->{status} // 0) == 405) {
            for my $pair (@$headers) {
                return $send->($event)
                    if ref($pair) eq 'ARRAY'
                        && defined $pair->[0]
                        && lc($pair->[0]) eq 'allow';
            }

            return $send->({
                %$event,
                headers => [@$headers, ['Allow' => $allow]],
            });
        }

        return $send->($event) unless $provenance->{returned_seed};

        my @filtered;
        my $removed_seed;
        for my $pair (@$headers) {
            if (!$removed_seed
                    && ref($pair) eq 'ARRAY'
                    && defined $pair->[0]
                    && lc($pair->[0]) eq 'allow'
                    && defined $pair->[1]
                    && $pair->[1] eq $allow) {
                $removed_seed = 1;
                next;
            }
            push @filtered, $pair;
        }

        return $send->($event) unless $removed_seed;
        return $send->({
            %$event,
            headers => \@filtered,
        });
    };
}

sub _select_http {
    my ($class, $compiled_entries, $scope) = @_;

    my $path = defined $scope->{path} ? $scope->{path} : '/';
    my $method = uc(defined $scope->{method} ? $scope->{method} : '');
    my @allowed_methods;
    my %method_seen;

    for my $entry (@$compiled_entries) {
        my $route = $entry->{route};
        my $captures = $route->_pattern->match_route($path);
        next unless defined $captures;

        my $methods = $route->methods;
        my $method_matches = !ref($methods) && $methods eq '*'
            ? 1
            : grep { $_ eq $method } @$methods;

        if ($method_matches) {
            my %path_params = (
                %{ref($scope->{path_params}) eq 'HASH' ? $scope->{path_params} : {}},
                %$captures,
            );
            my $matched_scope = {
                %$scope,
                path_params => \%path_params,
            };
            return {
                kind => 'full',
                app => $entry->{app},
                scope => $matched_scope,
            };
        }

        for my $allowed (@$methods) {
            next if $method_seen{$allowed}++;
            push @allowed_methods, $allowed;
        }
    }

    return {
        kind => 'partial',
        allowed_methods => [@allowed_methods],
    } if @allowed_methods;

    return { kind => 'none' };
}

1;

__END__

=head1 NAME

PAGI::Routing::Compiler - Internal declarative routing compiler

=head1 DESCRIPTION

Compiles declarative HTTP routing descriptions into fresh application graphs.
Full decisions invoke their selected leaf, while partial and none decisions
are rendered through the normal handler adapter as generated 405 and 404
responses. Generated response and Allow state remain request-local.

=cut
