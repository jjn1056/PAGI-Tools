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

# A Moose subclass built through MooseX::NonMoose calls this for the arguments
# to pass to this class's new. Moose sets the attributes and runs BUILD itself,
# so Class::Tiny's new is told to skip BUILD (the same flag Moo sends it).
sub FOREIGNBUILDARGS { return (__no_BUILD__ => 1) }

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::App - The base class for a PAGI application object

=head1 SYNOPSIS

    package MyApp {
        use v5.40;
        use parent 'PAGI::App';
        use Future::AsyncAwait;

        sub message ($self) { 'Hello, world' }

        async sub call ($self, $scope, $receive, $send) {
            die "Unsupported scope type: $scope->{type}\n"
                unless $scope->{type} eq 'http';

            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({
                type => 'http.response.body',
                body => $self->message,
                more => 0,
            });
        }
    }

    my $pagi_app = MyApp->new;   # an application provider: a server calls its to_app

=head1 INHERITANCE

    PAGI::App
      Class::Tiny::Object

C<PAGI::App> is a L<Class::Tiny> class: its constructor, C<new>, comes from
C<Class::Tiny::Object>.

=head1 RATIONALE

PAGI is Perl's version of Python's ASGI: the PAGI specification was modelled
on ASGI 3.0 (L<PAGI::Spec>), and PAGI-Tools follows the design of Starlette,
a toolkit for ASGI applications.

In ASGI an application is anything that can be called with
C<(scope, receive, send)>, and the server just calls it. A plain function
and an object whose class defines C<__call__> look exactly the same to the
server, so Python never has to tell the two apart: Starlette's applications,
routes and responses are all objects, and each one I<is> the application.

Perl can't do that. A PAGI application is called the same way, with
C<($scope, $receive, $send)>, returning a L<Future>, but only a code
reference can be called; an object can't. (Overloading C<&{}> comes close,
but the result is still not a native code reference, which is what the PAGI
specification's runner checks for first.) Yet most real applications carry
state, such as settings, connections and templates, for which an object is
the natural home.

So PAGI accepts both forms where Python needs only one. The application itself
is always a code reference, but a server should also accept an application
provider: an object with a C<to_app> method that returns one. The server calls
C<to_app> once, when it loads the object, and serves the code reference it gets
back (L<PAGI::Spec/Application Providers and Loading>).

C<PAGI::App> is the shim for the object form. A subclass writes C<call> as an
ordinary method, and C<to_app> returns a code reference that calls it, so a
Perl class can be an application the way a Python class with C<__call__> is.

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
application is an application provider, whatever its class; nothing checks for this
one.

=head1 METHODS

=head2 new

    my $app = MyApp->new(%args);

L<Class::Tiny>'s constructor. The arguments, name and value pairs, set the
attributes a class declares (C<< use Class::Tiny qw(name) >>, or with
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

=head2 FOREIGNBUILDARGS

For L<Moose> subclasses built with L<MooseX::NonMoose>: it hands this class's
C<new> nothing but the instruction to leave C<BUILD> to Moose, so C<BUILD> runs
once. You don't call it, and a Moose subclass doesn't need one of its own. See
L</With other object systems>.

=head1 COOKBOOK

=head2 Settings from the environment

A default can be a code reference, run the first time the attribute is read,
so a setting can come from C<%ENV> while C<new> needs no arguments:

    package Greeter {
        use v5.40;
        use parent 'PAGI::App';
        use Class::Tiny { greeting => sub { $ENV{GREETING} // 'Hello' } };
        use Future::AsyncAwait;

        async sub call ($self, $scope, $receive, $send) {
            die "Unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
            await $send->({ type => 'http.response.start', status => 200,
                            headers => [['content-type', 'text/plain']] });
            await $send->({ type => 'http.response.body', body => $self->greeting, more => 0 });
        }
    }

    Greeter->new;                        # "Hello", or whatever GREETING says
    Greeter->new(greeting => 'Howdy');   # an argument still wins

=head2 Your own constructor arguments

This is plain L<Class::Tiny>: C<PAGI::App> inherits its constructor, and with
it two hooks for arguments that aren't attributes, or a check on the ones that
are. C<BUILDARGS> reshapes the arguments before the object is built (see
L<Class::Tiny/Object construction>), and C<BUILD> checks the finished object
and dies if it's wrong (see L<Class::Tiny/BUILD>).

Here a redirect takes C<< permanent => 1 >>, which is easier to remember than
the status code, and refuses to build without a location:

    package Redirect {
        use v5.40;
        use parent 'PAGI::App';
        use Class::Tiny qw(location status);
        use Future::AsyncAwait;

        sub BUILDARGS ($class, %args) {
            my $permanent = delete $args{permanent};
            $args{status} //= $permanent ? 301 : 302;
            return \%args;
        }

        sub BUILD ($self, $args) {
            die "Redirect needs a location\n" unless defined $self->location;
        }

        async sub call ($self, $scope, $receive, $send) {
            die "Unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
            await $send->({ type => 'http.response.start', status => $self->status,
                            headers => [['location', $self->location]] });
            await $send->({ type => 'http.response.body', body => '', more => 0 });
        }
    }

    Redirect->new(location => '/new-home', permanent => 1);   # a 301
    Redirect->new(location => '/elsewhere');                   # a 302
    Redirect->new(permanent => 1);                             # dies: Redirect needs a location

=head2 With Moo

C<PAGI::App> is a L<Class::Tiny> class, and L<Moo> extends it as it is:
C<extends 'PAGI::App'>, then C<has> for the attributes. Here's the redirect
from the last recipe in Moo, with C<BUILD> keeping the check no C<has> clause
can make, one across two arguments:

    package Redirect {
        use v5.40;
        use Moo;
        extends 'PAGI::App';
        use Future::AsyncAwait;

        has location  => (is => 'ro', required => 1);
        has permanent => (is => 'ro');
        has status    => (is => 'ro', lazy => 1, default => sub ($self) { $self->permanent ? 301 : 302 });

        sub BUILD ($self, $args) {
            die "Redirect takes permanent or status, not both\n"
                if exists $args->{permanent} && exists $args->{status};
        }

        async sub call ($self, $scope, $receive, $send) {
            die "Unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
            await $send->({ type => 'http.response.start', status => $self->status,
                            headers => [['location', $self->location]] });
            await $send->({ type => 'http.response.body', body => '', more => 0 });
        }
    }

    Redirect->new(location => '/new-home', permanent => 1);             # a 301
    Redirect->new(location => '/elsewhere', status => 307);             # a 307
    Redirect->new(location => '/elsewhere', permanent => 1, status => 307);
                                         # dies: Redirect takes permanent or status, not both

=head2 With other object systems

The base is a convenience, not a requirement: anything with a C<to_app> that
returns a PAGI application is an application provider. So whatever you build
your classes with, either it extends C<PAGI::App>, or the class writes its own
C<to_app>.

=over 4

=item L<Moose>

Use L<MooseX::NonMoose>, as with any parent that isn't a Moose class:

    package Greeter {
        use v5.40;
        use Moose;
        use MooseX::NonMoose;
        extends 'PAGI::App';

        has name => (is => 'ro', required => 1);
        ...
    }

Without it, Moose leaves construction to the parent's C<new>, and your
attributes are never set.

=item L<Object::Pad>

Extends it as it is: C<class MyApp :isa(PAGI::App)>, with C<field ... :param>
for the arguments and C<ADJUST> for the checks.

=back

=head2 Unicode in and out

The scope's C<path> is characters: the server percent-decodes it and then
decodes the UTF-8, so a request for C</caf%C3%A9> has the path C</café>.
(C<raw_path> keeps the bytes the client sent.) A response body must be
bytes, so text is encoded before it is sent, and the Content-Type says which
encoding. C<use utf8> is what makes the non-ASCII characters written in the
source code characters too:

    package Hello {
        use v5.40;
        use utf8;
        use parent 'PAGI::App';
        use Encode ();
        use Future::AsyncAwait;

        async sub call ($self, $scope, $receive, $send) {
            die "Unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
            my $name = substr($scope->{path}, 1) || 'world';    # "/café" is "café"
            my $body = Encode::encode('UTF-8', "Grüß dich, $name ☺\n");
            await $send->({ type => 'http.response.start', status => 200,
                            headers => [['content-type', 'text/plain; charset=utf-8']] });
            await $send->({ type => 'http.response.body', body => $body, more => 0 });
        }
    }

A request for C</caf%C3%A9> gets the UTF-8 bytes of C<Grüß dich, café ☺>.

=head2 Serving it: Runnable for small things, a launcher for the rest

A server loads a file and needs the application back. For an application
whose settings come from the environment, a configuration file or defaults,
the module can be that file: inherit
L<PAGI::App::Runnable> and end the module with C<run_if_script> in place of
C<1;>:

    # lib/MyApp.pm -- serve with: pagi-server -Ilib --app lib/MyApp.pm
    package MyApp;
    use v5.40;
    use parent 'PAGI::App::Runnable';
    use Class::Tiny { greeting => sub { $ENV{GREETING} // 'Hello' } };
    ...
    __PACKAGE__->run_if_script;

When building the application takes more than defaults, such as reading a
configuration and building several objects from it, keep the module a plain
C<PAGI::App> and write a small launcher whose last value is the application:

    # launch.pl -- serve with: pagi-server -Ilib --app launch.pl
    use v5.40;
    use MyApp;
    my $config = load_config($ENV{MYAPP_CONFIG} // 'myapp.json');
    MyApp->new(dsn => $config->{dsn}, greeting => $config->{greeting});

L<PAGI::App::Runnable/CONSTRUCTOR ARGUMENTS> says what an application served
from its own module can and can't take.

=head1 SEE ALSO

L<PAGI::Spec>, L<PAGI::App::Runnable>, L<Class::Tiny>

=cut
