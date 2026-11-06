package PAGI::App::Runnable;

use v5.24;
use warnings;
use parent 'PAGI::App';

# The module's last line, in place of 1;. Loaded (pagi-server --app, require,
# use): the application. Run as the program: how to serve it.
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
    die "$0 is a PAGI application; serve it with:\n  pagi-server -Ilib --app $0\n";
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
F<app.pl> to keep in step with it. Run it with Perl, and it tells you how to
serve it.

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

A server loads the module, and C<run_if_script> builds the application with
C<new> and no arguments: there's no way to pass constructor arguments from the
server's command line. So if your application takes arguments, they have to
come from somewhere C<new> can reach on its own, such as C<%ENV> or a
configuration file, read by your attributes' defaults (see
L</Settings from a configuration file>). A setting it can't run without is
checked in C<BUILD>, so the server refuses to start without it (see
L</Testing it: set the environment before use>).

If building your application takes more than that, serve it from a launcher
instead (see L</A launcher, for construction that needs more>).

=head1 METHODS

=head2 run_if_script

    __PACKAGE__->run_if_script;

Put it on the module's last line, in place of C<1;>. When something loads the
module (a server's C<--app>, C<require> or C<use>), it returns
C<< $class->new >>, your PAGI application. When you run the file with Perl
(C<perl lib/MyApp.pm>), it builds nothing and dies with how to serve it.

It also records the module in C<%INC> under its module name. A server loads the
file by its path, and Perl records that under the path, not under
F<MyApp.pm>, so without this a later C<use MyApp> in the same process would
compile the whole file again. L<Web::Simple> does the same thing in its
C<import>.

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

=head2 Testing it: set the environment before use

Loading the module builds the application, so whatever C<new> reads from the
environment has to be in place before the module loads, in a test as much as
in a server. Here's an application that won't build without a database:

    package MyApp;
    use v5.40;
    use parent 'PAGI::App::Runnable';
    use Class::Tiny { dsn => sub { $ENV{MYAPP_DSN} } };

    sub BUILD ($self, $args) {
        die "MyApp needs a database: set MYAPP_DSN\n" unless defined $self->dsn;
    }

    ...

    __PACKAGE__->run_if_script;

A test sets C<MYAPP_DSN> in a C<BEGIN> block, before the C<use>. C<use> runs
at compile time, so a plain assignment on the line above it would come too
late:

    use v5.40;
    use Test2::V0;
    BEGIN { $ENV{MYAPP_DSN} = 'dbi:SQLite:dbname=:memory:' }
    use MyApp;

    is(MyApp->new->dsn, 'dbi:SQLite:dbname=:memory:', 'the test database');

    done_testing;

=head2 A launcher, for construction that needs more

When your application needs real constructor arguments, keep it a plain
L<PAGI::App> that takes them, and serve it from a launcher: a small module
that reads the configuration and builds the application. The application
stays an ordinary class, built with arguments, which is also how a test builds
it.

The application, F<lib/MyApp.pm>, needs a database and a secret:

    package MyApp;
    use v5.40;
    use parent 'PAGI::App';
    use Class::Tiny qw(dsn secret);
    use Future::AsyncAwait;

    sub BUILD ($self, $args) {
        for my $name (qw(dsn secret)) {
            die "MyApp needs $name\n" unless defined $self->$name;
        }
    }

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
            body => 'connected to ' . $self->dsn,
            more => 0,
        });
    }

    1;

The launcher, F<lib/MyApp/Launcher.pm>, is the module you point the server at.
It's the plain modulino line: loaded by the server, its last value is the
application it builds; run with Perl, it says how to serve it:

    package MyApp::Launcher;
    use v5.40;
    use JSON::PP ();
    use MyApp;

    sub app {
        my $file = $ENV{MYAPP_CONFIG} // 'myapp.json';
        open my $fh, '<', $file or die "Can't read $file: $!\n";
        my $config = JSON::PP::decode_json(do { local $/; <$fh> });

        return MyApp->new(dsn => $config->{dsn}, secret => $config->{secret});
    }

    caller ? app() : die "Serve it with: pagi-server -Ilib --app $0\n";

With F<myapp.json> holding C<{"dsn": "dbi:SQLite:app.db", "secret": "s3kr1t"}>:

    pagi-server -Ilib --app lib/MyApp/Launcher.pm

A test leaves the launcher out and builds the application itself:

    my $app = MyApp->new(dsn => 'dbi:SQLite:dbname=:memory:', secret => 'test');

=head1 SEE ALSO

L<PAGI::App>, L<Class::Tiny>, L<Web::Simple::Application>

=cut
