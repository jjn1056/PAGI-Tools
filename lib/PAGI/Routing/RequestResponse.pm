package PAGI::Routing::RequestResponse;

use strict;
use warnings;

use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use PAGI::Utils qw(invoke_app);

sub new {
    my ($class, @args) = @_;
    croak 'request_response option list must be key/value pairs'
        if @args % 2;

    my %allowed = map { $_ => 1 } qw(handler request_factory);
    my %seen;
    for (my $index = 0; $index < @args; $index += 2) {
        my $key = $args[$index];
        croak "unknown request_response option '$key'"
            unless defined $key && !ref($key) && $allowed{$key};
        croak "duplicate request_response option '$key'"
            if $seen{$key}++;
    }

    my %args = @args;
    my $handler = $args{handler};

    croak 'request_response handler must be a coderef'
        unless exists($args{handler}) && ref($handler) eq 'CODE';

    my $request_factory = $args{request_factory};
    croak 'request_response request_factory must be a coderef'
        if exists($args{request_factory}) && ref($request_factory) ne 'CODE';

    return bless {
        handler         => $handler,
        request_factory => $request_factory,
    }, $class;
}

sub to_app {
    my ($self) = @_;
    my $handler = $self->{handler};
    my $request_factory = $self->{request_factory};

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $type = $scope->{type} // '';
        croak "PAGI::Routing::RequestResponse requires HTTP, WebSocket, or SSE scope; received '$type'"
            unless $type eq 'http' || $type eq 'websocket' || $type eq 'sse';

        # An explicit request_factory wins; otherwise the scope decides.
        my $request;
        if ($request_factory) {
            $request = $request_factory->($scope, $receive);
            croak 'request_response request_factory must return a '
                . 'PAGI::Request instance or subclass'
                unless blessed($request) && $request->isa('PAGI::Request');
        }
        else {
            $request = PAGI::Utils::request_for_scope($scope, $receive);
        }
        my $run = async sub {
            my ($send) = @_;
            my $handler_result = $handler->($request);
            my $returned = await Future->wrap($handler_result);
            croak 'request handler returned nothing; a native ($scope, $receive, '
                . '$send) application given as a handler needs as_app_object()'
                unless defined $returned;
            PAGI::Utils::_validate_app_value(
                $returned,
                'request handler must return a PAGI application:',
            );
            return await invoke_app($returned, $scope, $receive, $send);
        };
        # An error the handler throws is answered at the route, with this
        # Request, by the ErrorHandler the scope carries (if any).
        my $error_handler = ($scope->{type} // '') eq 'http' ? $scope->{'pagi.error_handler'} : undef;
        return await $run->($send) unless $error_handler;
        my (undef, $result) = await $error_handler->_run_at_route($request, $scope, $receive, $send, $run);
        return $result;
    };
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Routing::RequestResponse - Adapt one Request handler to a PAGI application

=head1 SYNOPSIS

    use PAGI::Routing qw(request_response);

    my $application = request_response(sub {
        my ($request) = @_;
        return PAGI::Pages->not_found(detail => 'Missing');
    });

    my $special = request_response(
        \&reports,
        request_factory => sub {
            my ($scope, $receive) = @_;
            return MyCompany::Request->new($scope, $receive);
        },
    );

=head1 DESCRIPTION

L<PAGI::Routing/HANDLERS> says what a coderef means in each position.

This component adapts a one-Request handler into an app object, commonly for
Mount C<app>, for a custom Route helper, or for a bare handler passed to
L<PAGI::WebSocket/deny> or L<PAGI::SSE/decline>. The handler receives exactly one
L<PAGI::Request> and returns an immediate or Future-backed application value:
a native CODE or app object. Response and Pages objects are the ordinary
results. Do not use C<request_response> for ordinary
C<http_default> use: a bare CODE there already receives one Request. Compose
instead accepts route declarations only through C<routes>; an immutable Router
is preserved as an explicit Mount application within that list.

By default, each invocation constructs the Request its scope asks for: the
class a middleware such as L<PAGI::Middleware::RequestClass> set in the scope
key C<pagi.request.factory>, or a plain C<PAGI::Request>. An explicit
C<request_factory> wins over the scope. An optional
C<request_factory> coderef receives the exact C<($scope, $receive)> pair and
must synchronously return a C<PAGI::Request> instance or subclass. The factory
runs exactly once per invocation, before the handler, and must not return a
Future or consume the body. This explicit seam lets a project publish helpers
such as C<my_special_route($path, $handler)> while returning ordinary Route
objects; neither Route nor Router needs to know the custom Request class.

The component calls the handler once, normalizes a returned object through
C<to_app> once, and invokes the result against the exact original scope,
receive, and send. It does not cache a dynamic result across requests.

=head1 CONSTRUCTOR

=head2 new

    PAGI::Routing::RequestResponse->new(
        handler         => \&handler,
        request_factory => \&factory, # optional
    );

C<handler> is required and must be a coderef. C<request_factory> is optional
and must be a coderef. Without C<request_factory>, the scope decides, on every
invocation. Unknown, duplicate, and odd constructor options fail at
construction. The functional C<request_response> helper accepts the handler
positionally followed by the same optional C<request_factory> pair.

A returned application is delegation;
L<PAGI::Routing/Compilation and request lifecycle> says what it receives and
why a static one belongs in a route.

=head1 SEE ALSO

L<PAGI::Routing>, L<PAGI::Routing::Route>, L<PAGI::Response>, L<PAGI::Pages>,
L<PAGI::WebSocket>, and L<PAGI::SSE>.

=cut
