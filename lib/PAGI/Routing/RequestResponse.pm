package PAGI::Routing::RequestResponse;

use strict;
use warnings;

use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use PAGI::Request;
use PAGI::Utils qw(invoke_app);

sub new {
    my ($class, %args) = @_;
    my $handler = $args{handler};

    croak 'request_response handler must be a coderef'
        unless keys(%args) == 1 && exists($args{handler})
            && ref($handler) eq 'CODE';

    return bless { handler => $handler }, $class;
}

sub to_app {
    my ($self) = @_;
    my $handler = $self->{handler};

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $type = $scope->{type} // '';
        croak "PAGI::Routing::RequestResponse requires HTTP scope; received '$type'"
            unless $type eq 'http';

        my $request = PAGI::Request->new($scope, $receive);
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

=head1 DESCRIPTION

Callable position selects one of these contracts:

    Position                            Meaning
    ----------------------------------  --------------------------------
    Route endpoint / http_default CODE  one Request handler
    Route endpoint / http_default object app object via to_app
    Mount app CODE                       native PAGI application
    Mount app object                     app object via to_app

This component adapts a one-Request handler into Mount C<app>. The handler
receives exactly one L<PAGI::Request> and returns an immediate or Future-backed
application value: a native CODE or app object. Response and Pages objects are
the ordinary results. Do not use C<request_response> for ordinary
C<http_default> use: a bare CODE there already receives one Request. Compose
instead accepts route declarations only through C<routes>; an immutable Router
is preserved as an explicit Mount application within that list.

For each invocation the component constructs one Request, calls the handler
once, normalizes a returned object through C<to_app> once, and invokes the
result against the exact original scope, receive, and send. It does not cache a
dynamic result across requests.

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
