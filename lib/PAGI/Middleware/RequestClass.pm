package PAGI::Middleware::RequestClass;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Carp qw(croak);
use Future::AsyncAwait;
use PAGI::Request;
use PAGI::Utils ();

sub _init {
    my ($self, $config) = @_;

    croak 'RequestClass requires class'
        unless exists $config->{class};
    my $class = $config->{class};
    croak 'RequestClass class must be a package name'
        unless defined($class) && !ref($class)
            && $class =~ /\A[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*\z/;

    # Loaded now, so a typo fails when the application is built rather than
    # on every request.
    my $error = PAGI::Utils::_load_class($class, 'RequestClass', sub { $_[0]->isa('PAGI::Request') });
    croak $error if defined $error;
    croak "RequestClass $class is not a PAGI::Request"
        unless $class->isa('PAGI::Request');

    $self->{class} = $class;
    PAGI::Utils::_reject_unknown_options('RequestClass', $config, qw(class));
}

sub wrap {
    my ($self, $app) = @_;
    my $class = $self->{class};
    my $factory = sub {
        my ($scope, $receive) = @_;
        return $class->new($scope, $receive);
    };

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $type = $scope->{type} // '';
        unless ($type eq 'http' || $type eq 'websocket' || $type eq 'sse') {
            await $app->($scope, $receive, $send);
            return;
        }
        await $app->(
            $self->modify_scope($scope, { 'pagi.request.factory' => $factory }),
            $receive, $send,
        );
        return;
    };
}

1;

__END__

=head1 NAME

PAGI::Middleware::RequestClass - Hand every handler below it the application's Request class

=head1 SYNOPSIS

    use PAGI::Tools qw(compose middleware response route);

    package MyApp::Request {
        use parent 'PAGI::Request';

        sub greeting { return 'hello' }
    }

    my $app = compose(
        routes     => [route('/' => sub {
            my ($request) = @_;
            return response('Text', $request->greeting);
        })],
        middleware => [
            middleware('RequestClass', class => 'MyApp::Request'),
        ],
    );

C<middleware('RequestClass', ...)> also goes in a Router's, Mount's or
Route's C<middleware> list. It constructs the middleware and wraps the
application inside it, which you can do yourself:

    use PAGI::Middleware::RequestClass;

    my $wrapped = PAGI::Middleware::RequestClass->new(
        class => 'MyApp::Request',
    )->wrap($native_app);

Without Compose, L<PAGI::Middleware::Builder> composes middleware the way
Plack::Builder does.

=head1 DESCRIPTION

Every handler below this middleware that receives a Request receives a
C<class> object instead of a plain L<PAGI::Request>: route and
C<http_default> coderefs, L<PAGI::Endpoint::HTTP> methods, C<refuse> and
Maintenance C<response> handlers, the handlers given to
L<PAGI::WebSocket/deny> and L<PAGI::SSE/decline>, an
L<PAGI::Middleware::ErrorHandler> C<catch> entry answering a route's error
(it gets that route's Request), and an L<PAGI::Middleware::Authentication>
C<backend> listed after this middleware. An ErrorHandler C<handler> gets a
plain L<PAGI::Request> in Compose, which places it outside every application
middleware; in a stack you build yourself it gets the class when this
middleware wraps the ErrorHandler. It sets the scope key
C<pagi.request.factory> to C<< sub { $class->new($scope, $receive) } >> on a
shallow copy of HTTP, WebSocket and SSE scopes; other scope types pass
through unchanged. Code of your own builds the same class from the scope with
L<PAGI::Utils/request_for_scope>.

Use it when many handlers want the same few helpers. For one or two, a
function that takes the request is simpler and needs no middleware.

=over 4

=item * B<Order.> Middleware listed before this one does not see the class.
List it first.

=item * B<Mounts.> Applications mounted below it get the class too,
including ones you did not write.

=item * B<WebSocket and SSE.> The class's C<new> is also called with
WebSocket and SSE scopes (a C<deny> handler gets one). It must accept them,
as L<PAGI::Request/new> does.

=item * B<No receive.> The class's C<new> may be called with an undef
receive, for a Request that has no body (L<PAGI::Utils/request_for_scope>
without one). It must accept it, as L<PAGI::Request/new> does.

=item * B<A cheap constructor.> An endpoint built per request (see
L<PAGI::Endpoint>) gets one instance for its builder and another for its
method, so C<new> runs twice for that request. Keep it cheap, and never
read the body in it.

=item * B<Override.> C<request_response($handler, request_factory =E<gt> ...)>
still decides for its one handler (L<PAGI::Routing::RequestResponse>).

=item * B<Visibility.> The class is set by middleware, so the route tree does
not show it.

=item * B<Scope copies.> A middleware below this one that builds a new scope
without copying the old one's keys drops the class, as it would drop
C<pagi.auth>. Copy with L<PAGI::Utils::Middleware/clone_scope>.

=back

The same key can be set by hand, for a factory that is more than C<new>:

    middleware(sub ($app) {
        async sub ($scope, $receive, $send) {
            await $app->(clone_scope($scope, {
                'pagi.request.factory' => sub ($scope, $receive) { MyApp::Request->new($scope, $receive) },
            }), $receive, $send);
        }
    });

The factory is called with C<($scope, $receive)>, must return a
L<PAGI::Request> instance or subclass synchronously, and must not read the
body. C<$receive> may be C<undef>: L<PAGI::Utils/request_for_scope> called
without one passes C<($scope, undef)>, for a Request that has no body
(L<PAGI::Request/new>), so a factory must accept and pass on an undef
receive. An absent or undef key means a plain L<PAGI::Request>.

=head1 CONFIGURATION

An option not listed here dies at construction.

=over 4

=item * class (required)

A package name that is a L<PAGI::Request> subclass. A package already
defined as a L<PAGI::Request>, inline in your application file or loaded
earlier, is not loaded again; otherwise its file is loaded, even when other
code has already named the package. Either way it must then be a
L<PAGI::Request>. A name that cannot be loaded dies "RequestClass: cannot
load", and a
package that is not a L<PAGI::Request>, inline or loaded, dies "is not a
PAGI::Request", when the application is built, not on a request.

=back

=head1 SEE ALSO

L<PAGI::Request>, L<PAGI::Routing::RequestResponse>,
L<PAGI::Tools::Cookbook/An Application's Request Class>

=cut
