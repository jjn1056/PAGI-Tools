package PAGI::Routing::RequestResponse;

use strict;
use warnings;

use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use PAGI::Request;
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

    my $request_factory = exists $args{request_factory}
        ? $args{request_factory}
        : sub { return PAGI::Request->new(@_) };
    croak 'request_response request_factory must be a coderef'
        unless ref($request_factory) eq 'CODE';

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
        croak "PAGI::Routing::RequestResponse requires HTTP scope; received '$type'"
            unless $type eq 'http';

        my $request = $request_factory->($scope, $receive);
        croak 'request_response request_factory must return a '
            . 'PAGI::Request instance or subclass'
            unless blessed($request) && $request->isa('PAGI::Request');
        my $handler_result = $handler->($request);
        my $returned = await Future->wrap($handler_result);
        PAGI::Utils::_validate_app_value(
            $returned,
            'request handler must return a PAGI application:',
        );
        return await invoke_app($returned, $scope, $receive, $send);
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

Callable position selects one of these contracts:

    Position                            Meaning
    ----------------------------------  --------------------------------
    HTTP Route endpoint / http_default CODE  one Request handler
    HTTP Route endpoint / http_default object app object via to_app
    WebSocket Route endpoint CODE             one WebSocket handler
    WebSocket Route endpoint object           app object via to_app
    SSE Route endpoint CODE                   one SSE handler
    SSE Route endpoint object                 app object via to_app
    Mount app CODE                       native PAGI application
    Mount app object                     app object via to_app

This component adapts a one-Request handler into an app object, commonly for
Mount C<app> or for a custom Route helper. The handler receives exactly one
L<PAGI::Request> and returns an immediate or Future-backed application value:
a native CODE or app object. Response and Pages objects are the ordinary
results. Do not use C<request_response> for ordinary
C<http_default> use: a bare CODE there already receives one Request. Compose
instead accepts route declarations only through C<routes>; an immutable Router
is preserved as an explicit Mount application within that list.

By default, each invocation constructs one C<PAGI::Request>. An optional
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
and must be a coderef. Unknown, duplicate, and odd constructor options fail at
construction. The functional C<request_response> helper accepts the handler
positionally followed by the same optional C<request_factory> pair.

Arbitrary returned applications are advanced delegation. They receive the
unchanged HTTP scope and remaining receive stream; body events already consumed
through Request are not replayed. No lifespan startup or shutdown is replayed.
The returned app's routes, constraints, reverse names, and schema metadata are
opaque to the outer Router, and a nested app may apply another method/routing
policy or emit invalid events. Static or expensive app objects belong directly
in Route or another native application position.

Immediate synchronous handlers run inline. C<Future-E<gt>wrap> normalizes the
return value but does not offload CPU-heavy or blocking work from the event
loop.

=head1 SEE ALSO

L<PAGI::Routing>, L<PAGI::Routing::Route>, L<PAGI::Response>, and
L<PAGI::Pages>.

=cut
