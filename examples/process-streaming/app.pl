#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;
use Future::IO;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);

use PAGI::Compose  qw(compose);
use PAGI::Pages    qw(not_found);
use PAGI::Response qw(stream_response text_response);
use PAGI::Routing  qw(route router);

# ---------------------------------------------------------------------------
# A pull source over a child process's stdout.
#
# This is the whole adapter. Future::IO->read issues a read only when the
# consumer asks for one, so backpressure is structural: while the client is
# slow the pipe fills and the child blocks on write. Nothing accumulates in
# this process. It names no event loop, so the same code runs under any
# conforming PAGI server -- the server binds the Future::IO implementation
# (pagi-server does this for you).
# ---------------------------------------------------------------------------
package ProcessSource {
    sub new {
        my ($class, %args) = @_;
        return bless { fh => $args{fh}, size => $args{size} // 65536 }, $class;
    }

    # PAGI::Response::Writer::pipe_from needs exactly this one method:
    # bytes, or undef at end of stream, immediately or as a Future.
    sub next_chunk {
        my ($self) = @_;
        return Future::IO->read($self->{fh}, $self->{size});
    }
}

# Spawning needs no event loop at all: this is core Perl. The list form of
# open never involves a shell, so command arguments are not word-split or
# glob-expanded.
sub spawn_reader (@command) {
    my $pid = open(my $fh, '-|', @command)
        or die "cannot run $command[0]: $!\n";
    fcntl($fh, F_SETFL, fcntl($fh, F_GETFL, 0) | O_NONBLOCK);
    return ($fh, $pid);
}

# Commands are chosen from a fixed table and never built from request data.
# A report name selects an entry; it is never interpolated into a command.
my %REPORT = (
    # Emits a line every 50ms for 25 seconds: long enough to watch chunks
    # arrive progressively, and to see the child die when you disconnect.
    ticker => [
        $^X, '-e',
        '$| = 1; for my $n (1 .. 500) { print "tick $n\n"; select undef, undef, undef, 0.05 }',
    ],
    # Emits 5MB as fast as it can: exercises backpressure rather than time.
    bulk => [
        $^X, '-e',
        '$| = 1; binmode STDOUT; print "x" x 65536 for 1 .. 80',
    ],
);

async sub run_report ($request) {
    my $name    = $request->path_param('name');
    my $command = $REPORT{$name}
        or return not_found(detail => "No report named '$name'.");

    my ($fh, $pid) = spawn_reader(@$command);

    return stream_response(
        async sub ($writer) {
            # Runs exactly once, however this stream ends: normal completion,
            # a producer error, or the client vanishing mid-stream. That is
            # what stops the child when someone closes the browser tab.
            $writer->on_close(sub {
                kill 'TERM', $pid;
                return Future::IO->waitpid($pid);
            });

            await $writer->pipe_from(ProcessSource->new(fh => $fh));
        },
        content_type => 'text/plain; charset=utf-8',
    );
}

sub index_page ($request) {
    my $body = join "\n",
        'Available reports:',
        (map { "  /reports/$_" } sort keys %REPORT),
        '',
        'Try: curl -N http://localhost:5000/reports/ticker',
        'Then press Ctrl-C and watch the server stop the child process.',
        '';
    return text_response($body);
}

compose(
    app => router(
        routes => [
            route('/' => \&index_page,
                methods => ['GET'],
                name    => 'index',
                desc    => 'List the available reports',
            ),
            route('/reports/{name}' => \&run_report,
                methods => ['GET'],
                name    => 'report',
                desc    => 'Stream one report command as it runs',
            ),
        ],
        http_default => not_found(detail => 'No such page.'),
    ),
);
