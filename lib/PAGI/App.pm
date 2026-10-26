package PAGI::App;

use strict;
use warnings;
use Carp qw(croak);
use PAGI::Utils ();

our @METHODS = qw(GET HEAD POST PUT PATCH DELETE OPTIONS QUERY);
my %IS_METHOD = map { $_ => 1 } @METHODS;
my %HAS_BODY  = map { $_ => 1 } qw(POST PUT PATCH);

# Arguments as a list or one hashref, as Plack::Component and Moo accept.
sub new {
    my $class = shift;
    my %args = @_ == 1 && ref($_[0]) eq 'HASH' ? %{$_[0]} : @_;
    # A Moose subclass without MooseX::NonMoose arrives here instead of its
    # own new, and its required/default/BUILD would be silently ignored.
    my $error = PAGI::Utils::_moose_constructor_error($class, "PAGI::App subclass $class");
    croak $error if defined $error;
    return bless \%args, $class;
}

# Runs each time to_app builds the application.
sub prepare_app { return }

sub to_app {
    my ($self) = @_;
    $self->prepare_app;
    return sub { $self->call(@_) };
}

# The application: ($scope, $receive, $send), returning a Future. A classic
# application writes call; one that replaces the whole application overrides
# to_app.
sub call {
    my ($self) = @_;
    croak ref($self) . ' must implement call or override to_app';
}

# The module's last line, in place of 1;
#   loaded (pagi-server --app, require, use): an application provider that
#     builds nothing until a server calls its to_app;
#   run as a script: run(@ARGV), whose result is the exit status.
sub run_if_script {
    my $proto = shift;
    if (caller(1)) {
        # Loaded by path (pagi-server --app does "do /abs/lib/MyApp.pm"):
        # record it under its module name too, so a later "use MyApp" finds
        # it instead of compiling the file again.
        (my $key = (ref($proto) || $proto) . '.pm') =~ s{::}{/}g;
        $INC{$key} //= (caller(0))[1];
        return PAGI::App::_Deferred->new($proto);
    }
    my $self = ref($proto) ? $proto : $proto->new;
    exit $self->run(@ARGV);
}

# What running the module does: one HTTP request, printed. Override it to
# give the module commands of its own, and call SUPER::run for the request.
# Returns the exit status: 0 for 1xx-3xx, 1 for 4xx-5xx or a failed lifespan
# startup or shutdown, 2 for a usage error.
sub run {
    my ($self, @args) = @_;
    if (!@args || $args[0] =~ /\A(?:--help|-h)\z/) {
        print { @args ? *STDOUT : *STDERR } _usage();
        return @args ? 0 : 2;
    }
    my @request = eval { _parse_request(@args) };
    unless (@request) { print STDERR $@, _usage(); return 2 }

    my ($response, $shutdown_error) = eval { _request($self, @request) };
    unless ($response) { print STDERR $@; return 1 }

    binmode STDOUT;
    binmode STDERR;
    print STDERR 'HTTP/1.1 ', $response->status, "\n";
    print STDERR "$_->[0]: $_->[1]\n" for @{ $response->header_pairs };
    print STDERR "\n";
    print STDERR $response->exception, "\n" if defined $response->exception;
    print STDOUT $response->content;
    if (defined $shutdown_error) { print STDERR $shutdown_error; return 1 }
    return $response->status >= 400 ? 1 : 0;
}

# The command line's helpers are plain functions, called as functions, not
# methods: a subclass's own _request or _usage cannot replace them.

# [METHOD] PATH [Name: value | Content: text | name=value ...] -> the
# arguments for one PAGI::Test::Client request. Dies with a usage message.
sub _parse_request {
    my (@args) = @_;
    my $method = @args && $IS_METHOD{ $args[0] } ? shift @args : 'GET';
    my $target = shift @args;
    die "a path is required\n" unless defined $target;
    my ($credentials, $path) = $target =~ m{\A(?:([^/@\s]+)@)?(/.*)\z}s
        or die "not a method or a path: '$target' (methods: @METHODS)\n";
    # The argument is bytes; a URL carries them percent-encoded.
    $path =~ s/([\x80-\xFF])/sprintf('%%%02X', ord $1)/ge;

    my (@headers, @fields, $content);
    while (@args) {
        my $word = shift @args;
        if ($word =~ /\A([^:=\s]+):\z/) {
            my $name = $1;
            die "$name: needs a value\n" unless @args;
            if (lc($name) eq 'content') { $content = shift @args }
            else                       { push @headers, [$name, shift @args] }
        }
        elsif ($word =~ /\A([^=]+)=(.*)\z/s) { push @fields, [$1, $2] }
        else { die "not a header (Name: value) or a field (name=value): '$word'\n" }
    }
    die "a Content: body and form fields cannot be combined\n"
        if defined($content) && @fields;

    if (defined $credentials) {
        require MIME::Base64;
        push @headers,
            [Authorization => 'Basic ' . MIME::Base64::encode_base64($credentials, '')];
    }
    my %options = (headers => \@headers);
    # The fields are bytes, so they are encoded here, as the path is, rather
    # than handed to the test client, which takes characters.
    my $encoded = join '&', map { _escape($_->[0]) . '=' . _escape($_->[1]) } @fields;
    if (@fields && $HAS_BODY{$method}) {
        push @headers, ['Content-Type' => 'application/x-www-form-urlencoded'];
        $options{body} = $encoded;
    }
    elsif (@fields) {
        $path .= ($path =~ /\?/ ? '&' : '?') . $encoded;
    }
    $options{body} = $content if defined $content;
    return ($method, $path, %options);
}

# One request through $app, in-process, with lifespan startup before it and
# shutdown after, as a server's default (auto) mode runs it: an application
# that declines lifespan runs without it. Returns the PAGI::Test::Response
# and, when lifespan shutdown failed after the request was answered, its
# error.
sub _request {
    my ($app, $method, $path, %options) = @_;
    require PAGI::Test::Client;
    my $client = PAGI::Test::Client->new(app => $app, lifespan => 'auto');
    $client->start;
    my $call = lc $method;
    my $response = eval { $client->$call($path, %options) };
    my $error = $@;
    my $shutdown_error = eval { $client->stop; 1 } ? undef : $@;
    die $error unless $response;
    return ($response, $shutdown_error);
}

sub _escape {
    my ($text) = @_;
    $text =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord $1)/ge;
    return $text;
}

sub _usage {
    return <<"USAGE";
Usage: perl -Ilib $0 [METHOD] PATH [Name: value] [Content: text] [name=value]
  One request through the application, printed: status and headers on
  STDERR, the body on STDOUT. METHOD is one of @METHODS (default GET).
  user:pass\@/path sends Basic credentials. name=value is a form field: the
  query string for GET, a urlencoded body for POST, PUT and PATCH.
To serve it:
  pagi-server -Ilib --app $0
USAGE
}

package PAGI::App::_Deferred;

# Holds the class (or object) until a server asks for the application, so
# loading the module constructs nothing. Internal.
sub new    { my ($class, $proto) = @_; return bless { proto => $proto }, $class }
sub to_app { my $proto = $_[0]{proto}; return (ref($proto) ? $proto : $proto->new)->to_app }

1;

__END__

=head1 NAME

PAGI::App - A base class for PAGI applications, runnable from their own module

=head1 SYNOPSIS

A classic application writes C<call>, the PAGI application itself, in
F<lib/MyApp.pm>:

    package MyApp;
    use strict;
    use warnings;
    use parent 'PAGI::App';
    use Future::AsyncAwait;

    async sub call {
        my ($self, $scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200,
                        headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'pong' });
    }

    __PACKAGE__->run_if_script;

Serve it, or try one request from the shell without a server:

    pagi-server -Ilib --app lib/MyApp.pm
    perl -Ilib lib/MyApp.pm GET /

A Compose application subclasses L<PAGI::App::Compose> instead, and
declares its routes, middleware and lifespan in methods.

=head1 DESCRIPTION

An optional base class for an application: anything with C<to_app> is an
application, with or without it. It has the shape of L<Plack::Component>
(C<new>, C<prepare_app>, C<to_app>, C<call>), and the modulino of
L<Web::Simple::Application>: ending the module with
C<< __PACKAGE__->run_if_script >> in place of C<1;> makes the same file an
application a server loads and a program you can run.

A subclass does one of three things:

=over 4

=item * writes C<call>, the application, called with
C<($scope, $receive, $send)> and returning a L<Future>;

=item * subclasses L<PAGI::App::Compose> and declares a Compose
application's routes in methods; or

=item * overrides C<to_app> to return the whole application.

=back

The C<PAGI::App::*> modules (L<PAGI::App::File>, L<PAGI::App::URLMap> and the
rest) are applications shipped with PAGI::Tools, not subclasses of this one;
PAGI::App::Compose is the exception, a subclass for writing a Compose
application.

=head1 METHODS

=head2 new

    my $app = MyApp->new(%args);
    my $app = MyApp->new(\%args);

Blesses a hash of the arguments, given as a list or as one hashref. There is
no initialisation hook: a L<Moo> subclass validates with its attributes and
C<BUILD>, and a plain class overrides C<new>.

=head2 prepare_app

Called by C<to_app> each time it builds the application, before it returns.
Does nothing by default; a subclass that writes C<call> may set up here what
C<call> uses.

=head2 to_app

    my $code = $app->to_app;

Runs C<prepare_app> and returns the PAGI application: a code reference that
calls C<< $app->call($scope, $receive, $send) >>. Override it to return a
whole application of your own instead.

=head2 call

    async sub call { my ($self, $scope, $receive, $send) = @_; ... }

The application. The default dies "Class must implement call or override
to_app".

=head2 run_if_script

    __PACKAGE__->run_if_script;

The module's last line, in place of C<1;>. When the module is loaded (by a
server's C<--app>, by C<require> or by C<use>), it returns an application
provider: an object whose C<to_app> builds the application, with C<new> and
then C<to_app>, only when a server calls it. Loading the module therefore
constructs nothing. It also records the module in C<%INC> under its module
name, so a C<use MyApp> after a server loaded the file by its path does not
compile it again.

When Perl runs the file as the program, it builds the application with
C<new> and exits with what C<run> returns.

=head2 run

    my $exit_status = $app->run(@ARGV);

What running the module does: one HTTP request through the application,
printed (see L</THE COMMAND LINE>). It returns the exit status. Override it to
give the module commands of its own, and call C<SUPER::run> for the request:

    sub run {
        my ($self, @args) = @_;
        return $self->migrate if ($args[0] // '') eq 'migrate';  # perl lib/MyApp.pm migrate
        return $self->SUPER::run(@args);
    }

=head1 THE COMMAND LINE

    perl -Ilib lib/MyApp.pm [METHOD] PATH [ARGUMENT ...]

One HTTP request through the application, in-process, with no server, after
L<Web::Simple::Application>'s command line. WebSocket and SSE are tested with
L<PAGI::Test::Client>.

=over 4

=item * The first argument is a method if it is one of GET, HEAD, POST, PUT,
PATCH, DELETE, OPTIONS or QUERY; otherwise it is the path, which begins with
C</>, after optional C<user:pass@> Basic credentials. A method with no path,
or a first argument that is neither, is a usage error.

=item * C<Name: value>, a word ending in C<:> and the next word, is a request
header; C<Content: text> is the raw request body. C<name=value> is a form
field: a urlencoded body for POST, PUT and PATCH, added to the query string
otherwise. C<Content:> and form fields together are a usage error.

=item * Lifespan startup runs before the request and shutdown after it, as a
server's default (auto) mode runs them: an application that declines
lifespan, by raising on the C<lifespan> scope or returning without
signalling startup, runs without it; one that sends
C<lifespan.startup.failed> exits 1.

=item * The status line (C<HTTP/1.1 200>), every response header in order, a
blank line and, if the application died, its exception go to STDERR; the
body's bytes go to STDOUT, so C<< perl lib/MyApp.pm GET /x > out.json >>
keeps only the body.

=item * The exit status is 0 for 1xx to 3xx, 1 for 4xx and 5xx or a failed
lifespan startup or shutdown, and 2 for a usage error. A shutdown that fails
after the request was answered still prints the response, then its error on
STDERR. With no arguments the usage goes to STDERR
(exit 2); with C<--help> or C<-h>, to STDOUT (exit 0).

=back

Examples:

    perl -Ilib lib/MyApp.pm /                          # GET /
    perl -Ilib lib/MyApp.pm GET /search q=pagi         # GET /search?q=pagi
    perl -Ilib lib/MyApp.pm POST /notes title=Milk     # a urlencoded form
    perl -Ilib lib/MyApp.pm POST /notes Content-Type: application/json \
        Content: '{"title":"Milk"}'
    perl -Ilib lib/MyApp.pm GET ann:secret@/admin      # Basic credentials

It never starts a server: which PAGI server runs the application is not the
application's choice.

=head1 SERVING

    pagi-server -Ilib --app lib/MyApp.pm

A server builds the application with C<new> and no arguments, so the
application bootstraps its own configuration: attribute defaults, the
environment, or files it reads. A L<Moo> C<required> attribute without a
default cannot be served this way.

The application is recorded in C<%INC> when its last line runs, so code that
C<use>s the application class from the application module's own
compile-time C<use> lines would still load the file twice: do not do that.

=head1 MOO AND MOOSE

A L<Moo> class C<< extends 'PAGI::App' >> and keeps its attributes,
C<required>, C<default>, C<isa> and C<BUILD>; C<new> accepts the hashref
form Moo passes on. A L<Moose> class needs C<use MooseX::NonMoose> after
C<use Moose>; without it C<new> dies saying so, since the class's
attributes would otherwise be ignored.

=head1 SEE ALSO

L<PAGI::App::Compose>, L<Plack::Component>, L<Web::Simple::Application>, L<PAGI::Compose>,
L<PAGI::Test::Client>

=cut
