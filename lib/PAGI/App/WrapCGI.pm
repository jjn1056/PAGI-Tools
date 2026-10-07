package PAGI::App::WrapCGI;

use strict;
use warnings;

use Carp qw(croak);
use Encode ();
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Future;
use Future::AsyncAwait;
use IPC::Open3 ();
use PAGI::Response::Empty ();
use PAGI::Response::Stream ();
use PAGI::Response::Text ();
use PAGI::Utils ();
use PAGI::Utils::Scope ();
use Time::HiRes ();

=head1 NAME

PAGI::App::WrapCGI - Run a CGI script as a PAGI application

=head1 SYNOPSIS

    use PAGI::App::WrapCGI;

    my $app = PAGI::App::WrapCGI->new(
        script  => '/srv/cgi-bin/report.cgi',
        timeout => 10,
    )->to_app;

=head1 DESCRIPTION

Runs a CGI script (RFC 3875) for each HTTP request without blocking the event
loop. The script is started with L<IPC::Open3> -- no shell is involved -- and
its standard input and output are non-blocking pipes driven by L<Future::IO>:
the request body is streamed into the script while its output is read, so a
script that writes before reading all its input cannot deadlock, and the
response body streams to the client with backpressure.

The script's CGI header block sets the response: C<Status> sets the status, a
C<Location> without C<Status> answers 302, and other headers pass through
(C<Content-Length> and C<Transfer-Encoding> are dropped; the server frames the
body). A local redirect -- a C<Location> that is a bare path, which some
servers re-dispatch internally -- is sent to the client as a 302. The script's
standard error goes to the server's standard error.

A script runs for at most C<timeout> seconds. It is sent C<TERM>, then
C<KILL> two seconds later, when it times out or the client goes away, and it
is always reaped.

B<Platform.> Unix only: the script is forked, and its pipes are
non-blocking. The server must ignore C<SIGPIPE> -- a script that exits without
reading its input would otherwise end the server process when the body is
written to it; L<PAGI::Server> does. L<Future::IO> must be bound, as
C<pagi-server> does before loading the application.

=head2 Failures

    Script cannot be started                       500  CGI script could not be started
    Script exits before finishing its headers,
      or sends a malformed or oversized header block 500  CGI script sent no valid response
    Times out before sending its headers           504  CGI script timed out
    Request body without Content-Length over 10MB  413  Request body too large

Each is a plain-text response; C<refuse> replaces them. A script that times
out after its body has started is cut off: the status has already been sent,
so the response ends without its terminal body event and the application
reports the failure to the server.

=head2 Environment

The script receives the CGI variables and the server's C<PATH>, not the rest of
the server's environment. C<SCRIPT_NAME> and C<PATH_INFO> are decoded paths as
bytes and C<REQUEST_URI> is the path and query the client sent
(L<PAGI::Request/request_uri>); C<HTTPS> is C<on> for an https request.
Request headers become C<HTTP_*> variables, repeated headers joined with
C<, >, except C<Proxy>, which never becomes C<HTTP_PROXY> (httpoxy,
CVE-2016-5385). CGI requires C<CONTENT_LENGTH> for a body: a request body
without C<Content-Length> is read in full first, up to 10MB.

=head1 OPTIONS

=over 4

=item * C<script> (required) - Path to the CGI script to execute

=item * C<timeout> (default: 30) - Seconds a script may run

=item * C<refuse> (default: the plain-text failures above)

An application that answers a failure instead: a Request handler (a coderef called with one
L<PAGI::Request>, returning a Response or an application) or an object
with C<to_app>, which includes every L<PAGI::Response>.
It finds the reason in the scope as C<pagi.cgi_failure>: C<start>,
C<headers>, C<timeout> or C<body_too_large>. Any plain value dies.

A native C<($scope, $receive, $send)> application is passed as
C<as_app_object($app)>. Objects -- every Response and L<PAGI::Pages> value --
mean the same in every slot, and are the portable form for anything also
given to middleware outside PAGI-Tools.

=back

=cut

my $READ_SIZE      = 65536;
my $HEADER_LIMIT   = 65536;
my $BUFFERED_LIMIT = 10 * 1024 * 1024;
my $KILL_GRACE     = 2;

sub new {
    my ($class, %args) = @_;
    croak 'WrapCGI requires a script'
        unless defined($args{script}) && !ref($args{script}) && length($args{script});

    my $self = bless {
        script  => $args{script},
        timeout => $args{timeout} // 30,
        refuse  => PAGI::Utils::_refuse_option('WrapCGI', \%args),
    }, $class;
    $self->{_default_refusal} = {
        start          => PAGI::Response::Text->new('CGI script could not be started', status => 500)->to_app,
        headers        => PAGI::Response::Text->new('CGI script sent no valid response', status => 500)->to_app,
        timeout        => PAGI::Response::Text->new('CGI script timed out', status => 504)->to_app,
        body_too_large => PAGI::Response::Text->new('Request body too large', status => 413)->to_app,
    };
    return $self;
}

sub to_app {
    my ($self) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $type = $scope->{type} // '<missing>';
        croak "WrapCGI handles HTTP requests only, not '$type'" unless $type eq 'http';
        eval { require Future::IO; 1 }
            or croak "WrapCGI needs Future::IO, bound by the server: $@";

        # CGI needs CONTENT_LENGTH for a body: without one, read it all first.
        my $length = _content_length($scope);
        my $buffered;
        unless (defined $length) {
            $buffered = await _read_whole_body($receive);
            return await $self->_refuse($scope, $receive, $send, 'body_too_large')
                unless defined $buffered;
            $length = length $buffered;
        }

        my ($pid, $stdin, $stdout) = $self->_open_cgi($self->_environment($scope, $length));
        return await $self->_refuse($scope, $receive, $send, 'start') unless $pid;

        my $ends    = Time::HiRes::time() + $self->{timeout};
        my $exited  = Future::IO->waitpid($pid);
        my $feeding = _feed($stdin, $buffered, $receive);

        my ($outcome, $status, $headers, $content_type, $rest)
            = await _read_head($stdout, $ends);
        if ($outcome ne 'head') {
            _stop($pid, $exited);
            my $refused = await $self->_refuse($scope, $receive, $send, $outcome);
            # The response has gone; the request still owns the script until
            # it is reaped and its input is no longer being written.
            await Future->wait_all($exited, $feeding);
            return $refused;
        }

        # The script may still be running when its output is no longer
        # wanted: a timeout, a client that went away, a body that is not
        # allowed. Stop it, then wait for it so it is reaped.
        my $timed_out = 0;
        my $watchdog = Future::IO->sleep(_remaining($ends))
            ->on_done(sub { $timed_out = 1; _stop($pid, $exited) });
        my $finish = sub {
            $watchdog->cancel unless $watchdog->is_ready;
            _stop($pid, $exited);
            return Future->wait_all($exited, $feeding);
        };

        my @options = (status => $status, headers => $headers);
        push @options, content_type => $content_type if defined $content_type;

        my $response;
        if ($status == 204 || $status == 304) {
            await $finish->();
            $response = PAGI::Response::Empty->new(@options);
        }
        else {
            $response = PAGI::Response::Stream->new(async sub {
                my ($writer) = @_;
                $writer->on_close($finish);
                await $writer->write($rest) if length $rest;
                await $writer->pipe_from(PAGI::App::WrapCGI::_Output->new($stdout));
                die "CGI script timed out\n" if $timed_out;
            }, @options);
        }
        await PAGI::Utils::invoke_app($response, $scope, $receive, $send);
    };
}

# Starts the script with the given environment; returns ($pid, $stdin,
# $stdout), both pipes non-blocking, or nothing when it cannot be started.
sub _open_cgi {
    my ($self, $env) = @_;
    my ($stdin, $stdout);
    my $pid = eval {
        local %ENV = %$env;
        IPC::Open3::open3($stdin, $stdout, '>&STDERR', $self->{script});
    };
    return unless $pid;
    for my $fh ($stdin, $stdout) {
        binmode $fh;
        fcntl($fh, F_SETFL, fcntl($fh, F_GETFL, 0) | O_NONBLOCK);
    }
    return ($pid, $stdin, $stdout);
}

sub _environment {
    my ($self, $scope, $length) = @_;

    my $raw_path_info = PAGI::Utils::Scope::raw_path_info($scope);
    my %env = (
        GATEWAY_INTERFACE => 'CGI/1.1',
        SERVER_SOFTWARE   => 'PAGI-Tools',
        REQUEST_METHOD    => $scope->{method},
        SCRIPT_NAME       => Encode::encode('UTF-8', $scope->{root_path} // ''),
        PATH_INFO         => defined $raw_path_info
            ? PAGI::Utils::Scope::_unescape($raw_path_info)
            : Encode::encode('UTF-8', $scope->{path} // ''),
        REQUEST_URI       => PAGI::Utils::Scope::request_uri($scope),
        QUERY_STRING      => $scope->{query_string} // '',
        SERVER_PROTOCOL   => 'HTTP/' . ($scope->{http_version} // '1.1'),
        SERVER_NAME       => $scope->{server} ? $scope->{server}[0] // '' : '',
        SERVER_PORT       => $scope->{server} ? $scope->{server}[1] // '' : '',
        REMOTE_ADDR       => $scope->{client} ? $scope->{client}[0] // '' : '',
        REMOTE_PORT       => $scope->{client} ? $scope->{client}[1] // '' : '',
    );
    $env{HTTPS} = 'on' if ($scope->{scheme} // '') eq 'https';
    $env{PATH} = $ENV{PATH} if defined $ENV{PATH};
    $env{CONTENT_LENGTH} = $length if $length;

    my (%joined, @order);
    for my $header (@{ $scope->{headers} // [] }) {
        my ($name, $value) = @$header;
        (my $key = uc $name) =~ tr/-/_/;
        next if $key eq 'CONTENT_LENGTH';
        $key = "HTTP_$key" unless $key eq 'CONTENT_TYPE';
        next if $key eq 'HTTP_PROXY';    # httpoxy: never let a client set a proxy
        push @order, $key unless exists $joined{$key};
        push @{ $joined{$key} }, $value;
    }
    $env{$_} = join(', ', @{ $joined{$_} }) for @order;
    return \%env;
}

sub _content_length {
    my ($scope) = @_;
    for my $header (@{ $scope->{headers} // [] }) {
        return $header->[1] =~ /\A[0-9]+\z/ ? 0 + $header->[1] : undef
            if lc($header->[0]) eq 'content-length';
    }
    return undef;
}

# The whole request body, or undef when it is over the buffering limit.
async sub _read_whole_body {
    my ($receive) = @_;
    my $body = '';
    while (1) {
        my $event = await $receive->();
        last unless ($event->{type} // '') eq 'http.request';
        $body .= $event->{body} // '';
        return undef if length($body) > $BUFFERED_LIMIT;
        last unless $event->{more};
    }
    return $body;
}

# Writes the request body to the script's stdin and closes it. A script may
# exit without reading its input; that is not an error here.
async sub _feed {
    my ($stdin, $buffered, $receive) = @_;
    eval {
        if (defined $buffered) {
            await Future::IO->write_exactly($stdin, $buffered) if length $buffered;
        }
        else {
            while (1) {
                my $event = await $receive->();
                last unless ($event->{type} // '') eq 'http.request';
                await Future::IO->write_exactly($stdin, $event->{body})
                    if defined($event->{body}) && length($event->{body});
                last unless $event->{more};
            }
        }
        1;
    };
    # Closing is the script's end of input. Wait one turn of the loop first:
    # Future::IO completes a write inside its readiness callback and stops
    # watching the handle only after we return, and a handle closed before
    # then stays watched under a descriptor number the next pipe reuses.
    await Future::IO->sleep(0);
    close $stdin;
    return;
}

# The script's stdout is never closed here, for the reason _feed explains: it
# closes when the last reference goes, after Future::IO has let go of it.

# Reads the CGI header block. Returns ('head', $status, \@headers,
# $content_type, $rest), or ('headers') for a missing, malformed or oversized
# block, or ('timeout').
async sub _read_head {
    my ($stdout, $ends) = @_;
    my $buffer = '';
    while ($buffer !~ /\r?\n\r?\n/) {
        return ('headers') if length($buffer) > $HEADER_LIMIT;
        my $read  = Future::IO->read($stdout, $READ_SIZE);
        my $timer = Future::IO->sleep(_remaining($ends));
        eval { await Future->wait_any($read, $timer) };
        return ('timeout') if $read->is_cancelled;    # the timer won
        my $bytes = $read->is_done ? scalar $read->get : undef;
        return ('headers') unless defined($bytes) && length($bytes);
        $buffer .= $bytes;
    }
    my ($head, $rest) = $buffer =~ /\A(.*?)\r?\n\r?\n(.*)\z/s;

    my (@headers, $status, $content_type, $location);
    for my $line (split /\r?\n/, $head) {
        my ($name, $value) = $line =~ /\A([^:\s]+)[ \t]*:[ \t]*(.*?)[ \t]*\z/
            or return ('headers');
        my $lc = lc $name;
        if ($lc eq 'status') {
            ($status) = $value =~ /\A([1-5][0-9][0-9])\b/ or return ('headers');
        }
        elsif ($lc eq 'content-type') {
            $content_type = $value;
        }
        elsif ($lc ne 'content-length' && $lc ne 'transfer-encoding') {
            $location = 1 if $lc eq 'location';
            push @headers, $name => $value;
        }
    }
    $status //= $location ? 302 : 200;
    return ('head', 0 + $status, \@headers, $content_type, $rest);
}

sub _remaining { my ($ends) = @_; my $left = $ends - Time::HiRes::time(); return $left > 0 ? $left : 0 }

# Asks a running script to stop: TERM now, KILL after a grace period. The
# script's exit, which the request awaits, holds the escalation until then.
sub _stop {
    my ($pid, $exited) = @_;
    return if $exited->is_ready;
    kill 'TERM', $pid;
    my $escalation = Future::IO->sleep($KILL_GRACE)
        ->on_done(sub { kill 'KILL', $pid unless $exited->is_ready });
    $exited->on_ready(sub { $escalation->cancel unless $escalation->is_ready });
    return;
}

async sub _refuse {
    my ($self, $scope, $receive, $send, $reason) = @_;
    my $refusal = $self->{refuse} // $self->{_default_refusal}{$reason};
    await $refusal->({ %$scope, 'pagi.cgi_failure' => $reason }, $receive, $send);
}

# A pull source over the script's stdout for PAGI::Response::Writer::pipe_from.
package PAGI::App::WrapCGI::_Output;

sub new { my ($class, $fh) = @_; return bless { fh => $fh }, $class }

sub next_chunk {
    my ($self) = @_;
    return Future::IO->read($self->{fh}, $READ_SIZE)->else(sub { Future->done(undef) });
}

1;
