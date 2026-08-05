package PAGI::Routing::Compiler;

use strict;
use warnings;
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use PAGI::Context;
use PAGI::Routing::Middleware ();
use PAGI::Utils ();

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
    my ($class, $handler) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $context = PAGI::Context->new($scope, $receive, $send);
        my $returned = $handler->($context);
        my $result = await Future->wrap($returned);

        croak 'handler did not return a response'
            unless PAGI::Utils::is_response($result);

        await $context->respond($result);
        return;
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

Compiles declarative routing leaves and builds request-local selection
decisions. The public compilation entry point is completed by the generated
HTTP outcome layer.

=cut
