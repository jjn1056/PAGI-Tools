package PAGI::App::Runnable;

use v5.24;
use warnings;
use parent 'PAGI::App';

# The module's last line, in place of 1;. Loaded (pagi-server --app, require,
# use): the application. Run as the program: run, whose result is the exit status.
sub run_if_script {
    my ($class) = @_;
    # A server loads this file by its path (do lib/MyApp.pm), which Perl doesn't
    # record in %INC under the module's name. Record it, so a later "use MyApp"
    # in the same process doesn't compile the file a second time (redefining
    # every sub and building a second application). Web::Simple does the same:
    # `use Web::Simple` sets $INC{"${name}.pm"} (Web/Simple.pm, line 29 in 0.035).
    (my $key = "$class.pm") =~ s{::}{/}g;
    $INC{$key} //= (caller(0))[1];
    return $class->new if caller(1);
    exit $class->new->run(@ARGV);
}

# What running the module does. A placeholder until the command line exists.
sub run {
    my ($self, @args) = @_;
    print STDERR "$0 is a PAGI application; serve it with:\n  pagi-server -Ilib --app $0\n";
    return 2;
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::App::Runnable - A root application that a server loads from its own module

=head1 SYNOPSIS

A module file, F<lib/MyApp.pm>:

    package MyApp;
    use v5.40;
    use parent 'PAGI::App::Runnable';
    use Class::Tiny { greeting => sub { $ENV{GREETING} // 'Hello' } };
    use Future::AsyncAwait;

    async sub call ($self, $scope, $receive, $send) {
        die "Unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
        await $send->({ type => 'http.response.start', status => 200,
                        headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => $self->greeting, more => 0 });
    }

    __PACKAGE__->run_if_script;    # in place of 1;

Serve it:

    pagi-server -Ilib --app lib/MyApp.pm

=head1 INHERITANCE

    PAGI::App::Runnable
      PAGI::App
        Class::Tiny::Object

A root application adds itself to the top:

    MyApp
      PAGI::App::Runnable
        PAGI::App
          Class::Tiny::Object

=head1 RATIONALE

C<run_if_script> is the modulino pattern. That's brian d foy's name for an old
Perl trick: a file that acts like a module when something loads it, and like a
program when you run it. The classic version is a last line like

    __PACKAGE__->run(@ARGV) unless caller;

which runs the program only when nothing loaded the file.

We do the same thing, with one twist: when the file is loaded, we hand back
the PAGI application instead of C<1>. That's because whatever loads it is usually a
server, and C<pagi-server --app lib/MyApp.pm> needs a PAGI application back
from the file. So one module does both jobs: it's the class your PAGI application is
made of, and it's the file you point the server at. There's no separate
F<app.pl> to keep in step with it.

This is meant for small things: our examples and demos, and PAGI
applications whose settings come from the environment, a configuration file or
defaults. When it's loaded, it builds the
PAGI application with C<new> and no arguments (see L</CONSTRUCTOR ARGUMENTS>). If
building yours takes more than that, and for most real PAGI applications it will,
write a small launcher instead (see
L</A launcher, for construction that needs more>).

=head1 DESCRIPTION

A root application inherits from C<PAGI::App::Runnable> and ends its module
with C<< __PACKAGE__->run_if_script; >> in place of C<1;>. It writes C<call>,
as any L<PAGI::App> does.

=head1 CONSTRUCTOR ARGUMENTS

Loaded, C<run_if_script> calls C<new> with B<no arguments>, and so does running
the module as a program. So C<new> must succeed with no arguments, given the
environment the application runs in, and each attribute gets its value from a
default. A default may be a code reference,
run the first time the attribute is read, so it can read C<%ENV> or a
configuration file. Settings then resolve in this order:

=over 4

=item 1. an argument given to C<new> (a test passes its own);

=item 2. an environment variable;

=item 3. a configuration file;

=item 4. the default.

=back

L<Moo> and L<Moose> classes do the same with C<lazy> attributes and a
C<default>, rather than C<required>.

Loading the module builds the application with C<new> and no arguments, so a
setting the application can't run without is checked in C<BUILD>, and
whatever C<BUILD> needs must be in place before the module is loaded: the
server refuses to start without it, and a test sets it before C<use MyApp>.
In a test that means a C<BEGIN> block, because C<use> runs at compile time, so
the environment has to be set at compile time too. (Or set it with
C<local $ENV{...}> and C<require MyApp> at run time.) See
L</A setting the application must have>.

Opening connections is different: don't do it in C<BUILD>, which runs every
time the module is loaded, a test's C<use> included. Open them the first time
they're needed, from an attribute's default.

An application whose construction needs more than defaults can give, such as
several objects built from one configuration, is better served from a
launcher than from C<run_if_script>: see
L</A launcher, for construction that needs more>.

=head1 METHODS

=head2 run_if_script

    __PACKAGE__->run_if_script;

Put it on the module's last line, in place of C<1;>. When something loads the
module (a server's C<--app>, C<require> or C<use>), it returns
C<< $class->new >>, your PAGI application. When you run the file with Perl
(C<perl lib/MyApp.pm ...>), it calls C<< $class->new->run(@ARGV) >> and exits
with whatever C<run> returns.

It also records the module in C<%INC> under its module name. A server loads the
file by its path, and Perl records that under the path, not under
F<MyApp.pm>, so without this a later C<use MyApp> in the same process would
compile the whole file again. L<Web::Simple> does the same thing in its
C<import>.

=head2 run

    my $status = $app->run(@args);

What running the module as a program does, returning its exit status. For
now it prints how to serve the file and returns C<2>. Override it to give the
module commands of its own, and call C<SUPER::run> for anything else.

=head1 COOKBOOK

=head2 Settings from a configuration file

A lazy C<config> attribute reads the file the first time a setting needs it,
and each setting's default looks in C<%ENV>, then the file, then falls back:

    package MyApp {
        use v5.40;
        use parent 'PAGI::App::Runnable';
        use JSON::PP ();
        use Class::Tiny {
            config => sub {
                my $file = $ENV{MYAPP_CONFIG} // 'myapp.json';
                return {} unless -e $file;
                open my $fh, '<', $file or die "Can't read $file: $!\n";
                return JSON::PP::decode_json(do { local $/; <$fh> });
            },
            dsn      => sub ($self) { $ENV{MYAPP_DSN} // $self->config->{dsn} },
            greeting => sub ($self) { $ENV{MYAPP_GREETING} // $self->config->{greeting} // 'Hello' },
        };

        __PACKAGE__->run_if_script;
    }

A test that passes C<< dsn => 'test' >> gets C<test>, and the file isn't read
for it.

=head2 A setting the application must have

C<dsn> has no default, so C<BUILD> refuses to build the application without
it. Loading the module builds it, so the server refuses to start. The module
file, F<lib/MyApp.pm>:

    package MyApp;
    use v5.40;
    use parent 'PAGI::App::Runnable';
    use Class::Tiny { dsn => sub { $ENV{MYAPP_DSN} } };
    use Future::AsyncAwait;

    sub BUILD ($self, $args) {
        die "MyApp needs a database: set MYAPP_DSN\n" unless defined $self->dsn;
    }

    async sub call ($self, $scope, $receive, $send) {
        die "Unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
        await $send->({ type => 'http.response.start', status => 200,
                        headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'connected to ' . $self->dsn, more => 0 });
    }

    __PACKAGE__->run_if_script;

Without C<MYAPP_DSN>, C<pagi-server -Ilib --app lib/MyApp.pm> stops with
"Error loading .../lib/MyApp.pm: MyApp needs a database: set MYAPP_DSN". End
the message with a newline, or Perl adds the file and line to it.

A test loads the module too, so it sets the setting first, in a C<BEGIN>
block, before the C<use>:

    use v5.40;
    use Test2::V0;
    BEGIN { $ENV{MYAPP_DSN} = 'dbi:SQLite:dbname=:memory:' }
    use MyApp;

    is(MyApp->new->dsn, 'dbi:SQLite:dbname=:memory:', 'the test database');

    done_testing;

=head2 A launcher, for construction that needs more

When building the application takes more than defaults, write a small file
that builds it, and serve that file instead. The application itself is then a
plain L<PAGI::App>, built like any other object, and doesn't need this class:

    # launch.pl -- serve with: pagi-server -Ilib --app launch.pl
    use v5.40;
    use JSON::PP ();
    use MyApp;

    my $file   = $ENV{MYAPP_CONFIG} // 'myapp.json';
    my $config = do { open my $fh, '<', $file or die "Can't read $file: $!\n";
                      JSON::PP::decode_json(do { local $/; <$fh> }) };
    MyApp->new(dsn => $config->{dsn}, greeting => $config->{greeting});

The file's last value is what the server gets. C<-Ilib> goes on the command
line, not in the file.

=head2 A command of its own

C<run> is what C<perl lib/MyApp.pm> does. Override it, and pass anything else
on to C<SUPER::run>:

    package MyApp {
        use v5.40;
        use parent 'PAGI::App::Runnable';

        sub run ($self, @args) {
            if (($args[0] // '') eq 'version') {
                say 'MyApp 1.0';
                return 0;
            }
            return $self->SUPER::run(@args);
        }

        __PACKAGE__->run_if_script;
    }

    # perl lib/MyApp.pm version    prints "MyApp 1.0", exits 0

=head1 SEE ALSO

L<PAGI::App>, L<Class::Tiny>, L<Web::Simple::Application>

=cut
