package PAGI::Compose::Compiler;

use strict;
use warnings;
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed refaddr);
use PAGI::Routing::HeadBoundary ();
use PAGI::Routing::Middleware ();
use PAGI::Routing::Router ();
use PAGI::Utils ();

my $STATE_KEY = "\0PAGI::Compose::Compiler::lifespan_state";
my $STATE_TOKEN = sub { return };

sub compile {
    my ($class, $description) = @_;
    croak 'compose description is required'
        unless blessed($description) && $description->isa('PAGI::Compose');

    my $target = $class->_compile_target($description);
    my $lifespan = $description->lifespan;
    my $dispatcher = async sub {
        my ($scope, $receive, $send) = @_;
        if (($scope->{type} // '') eq 'lifespan') {
            await $class->_run_lifespan($lifespan, $scope, $receive, $send);
            return;
        }

        my $returned = $target->($scope, $receive, $send);
        await Future->wrap($returned);
        return;
    };

    my $app = PAGI::Routing::Middleware->_wrap_descriptors(
        $description->middleware,
        $dispatcher,
    );

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $provenance_scope = $class->_prepare_lifespan_scope($scope);
        my ($inner_scope, $wire_send)
            = PAGI::Routing::HeadBoundary->prepare($provenance_scope, $send);
        my $returned = $app->($inner_scope, $receive, $wire_send);
        await Future->wrap($returned);
        return;
    };
}

sub _compile_target {
    my ($class, $description) = @_;
    my $routes = $description->routes;
    if (defined $routes) {
        return PAGI::Routing::Router->new(routes => $routes)->to_app;
    }
    return PAGI::Utils::to_app($description->app);
}

sub _prepare_lifespan_scope {
    my ($class, $scope) = @_;
    return $scope unless ($scope->{type} // '') eq 'lifespan';

    my $state = ref($scope->{state}) eq 'HASH' && !blessed($scope->{state})
        ? $scope->{state}
        : undef;
    my $inner_scope = { %$scope };
    $inner_scope->{$STATE_KEY} = [$STATE_TOKEN, $state];
    return $inner_scope;
}

sub _verified_state {
    my ($class, $scope) = @_;
    my $proof = $scope->{$STATE_KEY};
    return unless ref($proof) eq 'ARRAY' && @$proof == 2;
    return unless ref($proof->[0])
        && refaddr($proof->[0]) == refaddr($STATE_TOKEN);

    my $original = $proof->[1];
    my $current = $scope->{state};
    return unless ref($original) eq 'HASH' && !blessed($original);
    return unless ref($current) eq 'HASH' && !blessed($current);
    return unless refaddr($current) == refaddr($original);
    return $current;
}

async sub _callback_error {
    my ($class, $callback, $state, $scope) = @_;
    return unless $callback;

    my $ok = eval {
        my $returned = $callback->($state, $scope);
        await Future->wrap($returned);
        1;
    };
    my $error = "$@";
    return $ok ? undef : $error;
}

async sub _run_lifespan {
    my ($class, $lifespan, $scope, $receive, $send) = @_;
    my $configured = defined $lifespan;
    my $started = 0;
    my $state;

    while (1) {
        my $message = await Future->wrap($receive->());
        my $type = $message->{type} // '';

        if ($type eq 'lifespan.startup' && !$started) {
            if ($configured) {
                $state = $class->_verified_state($scope);
                unless ($state) {
                    await Future->wrap($send->({
                        type => 'lifespan.startup.failed',
                        message => 'PAGI::Compose lifespan requires server state support',
                    }));
                    return;
                }
                my $error = await $class->_callback_error(
                    $lifespan->{startup}, $state, $scope,
                );
                if (defined $error) {
                    await Future->wrap($send->({
                        type => 'lifespan.startup.failed',
                        message => $error,
                    }));
                    return;
                }
            }
            await Future->wrap($send->({ type => 'lifespan.startup.complete' }));
            $started = 1;
        }
        elsif ($type eq 'lifespan.shutdown' && $started) {
            my $error = $configured
                ? await $class->_callback_error(
                    $lifespan->{shutdown}, $state, $scope,
                )
                : undef;
            if (defined $error) {
                await Future->wrap($send->({
                    type => 'lifespan.shutdown.failed',
                    message => $error,
                }));
            }
            else {
                await Future->wrap($send->({ type => 'lifespan.shutdown.complete' }));
            }
            return;
        }
    }
}

1;

__END__

=head1 NAME

PAGI::Compose::Compiler - Internal compiler for PAGI::Compose

=head1 DESCRIPTION

This module is the internal compilation engine used by
L<PAGI::Compose/to_app>. It is not a public constructor; applications should
create a L<PAGI::Compose> description and compile that description instead.

Each compilation builds a target, middleware graph, dispatcher, and final HEAD
wire boundary. All request/lifespan phase, callback, server-state proof, and
HEAD-send state is local to one application invocation. None is retained on
the Compose description or shared between concurrent scopes.

=cut
