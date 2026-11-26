package PAGI::Middleware;

use v5.24;
use warnings;
use parent 'PAGI::App';
use Carp ();
use Scalar::Util ();
use Class::Tiny qw(app);

# Plack's wrap: on an instance it sets app; on the class it builds one with
# the options given after the app. Either way the result is the middleware
# as an application, a code reference.
sub wrap {
    my ($self, $app, @options) = @_;
    $app = _application($app);
    return $self->new(@options, app => $app)->to_app unless ref $self;
    $self->app($app);
    return $self->to_app;
}

# The application as a code reference: one already, or an object's to_app.
sub _application {
    my ($app) = @_;
    return $app if ref $app eq 'CODE';
    return $app->to_app if Scalar::Util::blessed($app) && $app->can('to_app');
    Carp::croak('wrap takes an application: a code reference or an object with to_app');
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Middleware - The base class for PAGI middleware

=head1 SYNOPSIS

    package MyApp::Tag {
        use v5.40;
        use parent 'PAGI::Middleware';
        use Class::Tiny { tag => 'default' };
        use Future::AsyncAwait;

        async sub call ($self, $scope, $receive, $send) {
            await $self->app->({ %$scope, 'myapp.tag' => $self->tag }, $receive, $send);
        }
    }

    my $wrapped = MyApp::Tag->wrap($app, tag => 'blue');     # a code reference
    my $same    = MyApp::Tag->new(tag => 'blue')->wrap($app);

=head1 INHERITANCE

    PAGI::Middleware
      PAGI::App
        Class::Tiny::Object

=head1 DESCRIPTION

A middleware is an application that holds the application it wraps. It's
L<Plack::Middleware>'s contract on L<PAGI::App>: you write C<call>, which
does its work around a call to C<< $self->app >>, and C<wrap> gives you the
middleware as an application, a code reference a server can call.

Options are your class's own L<Class::Tiny> attributes, given as name/value
pairs, to C<wrap> after the app or to C<new>.

One instance wraps one application: calling C<wrap> on an instance again
replaces its C<app>. To wrap two applications, use two instances, or C<wrap>
on the class.

=head2 Hand the inner app a copy of the scope

To pass something to the application you wrap, give it a copy of the scope
with your key added, and leave the scope you were given alone:

    await $self->app->({ %$scope, 'myapp.user' => $user }, $receive, $send);

The scope you were given is shared with the layers around you. A key you
set in it leaks out to them, and on a WebSocket it stays there for every
event of the connection. A copy keeps your key for the layers inside you.
The copy is shallow, so what the scope's values point to, the
C<pagi.connection> object say, is still shared, as it must be.

=head1 METHODS

=head2 wrap

    my $wrapped = MyMiddleware->wrap($app, %options);
    my $wrapped = MyMiddleware->new(%options)->wrap($app);

Returns the middleware around C<$app> as an application, a code reference.
On the class, it builds the middleware with C<%options> first. On an
instance, it sets the instance's C<app>.

C<$app> is a code reference, or an object with C<to_app>, such as a
L<PAGI::App>; anything else dies.

A subclass may override C<wrap> to return a code reference of its own
making instead. All C<wrap> promises is an application.

=head2 app

    my $inner = $self->app;

The application this middleware wraps, always a code reference. Call it in
your C<call> with C<($scope, $receive, $send)>, and await what it returns.

=head2 call

    async sub call ($self, $scope, $receive, $send) { ... }

Yours to write, as for any L<PAGI::App>.

=head1 SEE ALSO

L<PAGI::App>, L<Plack::Middleware>

=cut
