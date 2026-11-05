package PAGI::App;

use v5.24;
use warnings;
use Carp ();
use Class::Tiny;

# The application: called with ($scope, $receive, $send), returning a Future.
sub call {
    my ($self) = @_;
    Carp::croak(ref($self) . ' must implement "call" or override "to_app"');
}

# The object as a PAGI application: the stand-in for a callable object.
sub to_app {
    my ($self) = @_;
    return sub { $self->call(@_) };
}

1;

__END__

=head1 NAME

PAGI::App - The base class for a PAGI application object

=head1 SYNOPSIS

    package MyApp {
        use v5.40;
        use parent 'PAGI::App';
        use Class::Tiny { greeting => 'Hello' };
        use Future::AsyncAwait;

        async sub call ($self, $scope, $receive, $send) {
            await $send->({ type => 'http.response.start', status => 200,
                            headers => [['content-type', 'text/plain']] });
            await $send->({ type => 'http.response.body', body => $self->greeting, more => 0 });
        }
    }

    MyApp->new(greeting => 'Hi');   # an application: a server calls its to_app

=head1 INHERITANCE

    PAGI::App
      Class::Tiny::Object

C<PAGI::App> is a L<Class::Tiny> class: its constructor, C<new>, comes from
C<Class::Tiny::Object>.

=head1 RATIONALE

A PAGI application is a code reference, called with
C<($scope, $receive, $send)> and returning a L<Future>. Most real
applications also carry state: settings, connections, templates. An object
is the natural home for that.

In Python an object can be the application itself: a class that defines
C<__call__> makes its instances callable, which is how Starlette's
applications, routes and responses all work. A Perl object cannot be called
as a code reference. Overloading C<&{}> comes close, but the result is still
not a native code reference, which is what the PAGI specification's runner
checks for first. So PAGI's convention is C<to_app>: an object with a
C<to_app> method is asked, once, for the code reference
(L<PAGI::Spec::Server/Application Loading and Normalization>).

C<PAGI::App> writes that adapter once. A subclass writes C<call> as an
ordinary method, and C<to_app> turns the object into the code reference.

It is built on L<Class::Tiny>: small, with no dependencies outside the Perl
core, and it gives accessors with defaults, C<BUILDARGS> and C<BUILD>. A
default can be a code reference run on first use, which is how an
application takes its settings from C<%ENV> or a configuration file without a
constructor argument.

=head1 DESCRIPTION

An application object: a class whose instances are PAGI applications. A
subclass writes C<call>, the application, or overrides C<to_app> to return a
whole application of its own.

The base is optional. Anything with a C<to_app> that returns a PAGI
application is an application, whatever its class; nothing checks for this
one.

=head1 METHODS

=head2 new

    my $app = MyApp->new(%args);
    my $app = MyApp->new(\%args);

L<Class::Tiny>'s constructor. The arguments, as a list or one hashref, set
the attributes a class declares (C<< use Class::Tiny qw(name) >>, or with
defaults, C<< use Class::Tiny { name => 'nobody' } >>). A default may be a code
reference, run on first use with the object as its argument, so a setting can
come from C<%ENV> or a configuration file. Undeclared arguments are ignored.
C<BUILDARGS> reshapes the arguments and C<BUILD> validates, parent first.

=head2 call

    async sub call ($self, $scope, $receive, $send) { ... }

The application. The default croaks: a subclass must write it, or override
C<to_app>.

=head2 to_app

    my $code = $app->to_app;

Returns the PAGI application: a code reference that calls
C<< $app->call($scope, $receive, $send) >>.

You rarely call this yourself. Whatever runs or composes the application
calls it when handed the object: a server (C<pagi-server --app>, which asks
once, as the specification says), or a router or mount it is passed to. It is
mostly useful in tests, or to hand the application to something that takes
only a code reference.

=head1 SEE ALSO

L<PAGI::Spec>, L<Class::Tiny>

=cut
