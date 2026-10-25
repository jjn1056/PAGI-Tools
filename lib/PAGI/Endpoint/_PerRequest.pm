package PAGI::Endpoint::_PerRequest;

# The app object endpoint('Class') returns for a class built per request
# (PAGI::Endpoint per_request_app): a class without BUILD_APP, built with
# new, or one whose BUILD_APP returns a builder. Each request, or each
# WebSocket or SSE connection, gets its own app object from the builder, and
# that object run. A builder from BUILD_APP is given the Request (the class
# RequestClass set, or a plain PAGI::Request); a class built with new needs
# none, so none is built here: the object's own to_app makes what it needs.
# Internal: not constructed directly, not public API.

use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use PAGI::Utils qw(invoke_app);

sub new {
    my ($class, %args) = @_;
    return bless { class => $args{class}, build => $args{build},
        request => $args{request} // 1 }, $class;
}

sub to_app {
    my ($self) = @_;
    my ($class, $build, $wants_request) = @{$self}{qw(class build request)};
    my $made_by = $wants_request ? "$class->BUILD_APP's builder" : "$class->new";

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $request = $wants_request
            ? PAGI::Utils::request_for_scope($scope, $receive)
            : undef;
        # A builder returns an app object, or a Future of one (an async builder).
        # A builder given the Request shares it with the handler, so its error
        # is answered at the route with that Request (spec D2, Q-R2).
        my $app;
        my $error_handler = $request && ($scope->{type} // '') eq 'http'
            ? $scope->{'pagi.error_handler'} : undef;
        if ($error_handler) {
            my ($completed, $built) = await $error_handler->_run_at_route($request, $scope, $receive, $send,
                async sub { await Future->wrap($build->($request)) });
            return unless $completed;
            $app = $built;
        }
        else {
            $app = await Future->wrap($build->($request));
        }
        croak "$made_by must return an app object (one with to_app);"
            . ' a native PAGI application goes through as_app_object()'
            unless blessed($app) && $app->can('to_app');
        # An HTTP endpoint answers with the Request its builder was given, so
        # the body the builder read is the handler's too; its own to_app
        # (scope checks, a subclass's wrapping) still runs and takes it.
        $app->{_pagi_builder_request} = $request
            if $request && $app->isa('PAGI::Endpoint::HTTP');
        await invoke_app($app, $scope, $receive, $send);
    };
}

package PAGI::Endpoint::_PerRequest::HTTP;

# The wrapper for an HTTP class. A WebSocket or SSE route never asks for
# allowed_methods, so only this one has it.
our @ISA = ('PAGI::Endpoint::_PerRequest');

# Asked once by Route; answered by the class, which is never built for it.
sub allowed_methods {
    my ($self) = @_;
    return $self->{class}->allowed_methods;
}

1;
