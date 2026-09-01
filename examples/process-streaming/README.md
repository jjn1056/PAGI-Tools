# Process Streaming Example

Stream the output of an external command as an HTTP response, with real
backpressure, and stop the command the moment the client goes away.

```bash
pagi-server --app examples/process-streaming/app.pl --port 5000

curl http://localhost:5000/
curl -N http://localhost:5000/reports/ticker    # then press Ctrl-C
curl -s http://localhost:5000/reports/bulk | wc -c
```

## What it demonstrates

**A direct declarative root.** The application gives Compose its two root
routes with `routes => [...]` and its `http_default` directly, so no separate
Router needs to be retained just to deploy this small HTTP application.

**A four-line source adapter.** `PAGI::Response::Writer::pipe_from` needs one
method — `next_chunk`, returning bytes or `undef` at end of stream, immediately
or as a Future. A child process's stdout becomes a response body with:

```perl
sub next_chunk {
    my ($self) = @_;
    return Future::IO->read($self->{fh}, $self->{size});
}
```

**Backpressure you get for free.** `Future::IO->read` issues a read only when
the consumer asks for one. While the client is slow, nothing accumulates in the
server: the pipe fills and the child blocks on `write`. Requesting
`/reports/bulk` through a slow client streams 5MB with no growth in resident
memory, because the toolkit never buffers ahead of the socket.

**Cleanup that fires on every ending.** `on_close` runs exactly once, whether
the stream finished normally, the producer threw, or the client disconnected
mid-response:

```perl
$writer->on_close(sub {
    kill 'TERM', $pid;
    return Future::IO->waitpid($pid);
});
```

Start `/reports/ticker`, press Ctrl-C, and the child process is gone within a
tick — the server stops *computing*, not just stops writing. That is PAGI's
disconnect contract doing visible work: a pending send settles when the client
disappears, the connection state is already updated when your code resumes, and
the toolkit turns that into one cleanup callback.

**No event loop is named anywhere in this application.** Spawning is core Perl
(`open '-|'`), reading is `Future::IO->read`, reaping is
`Future::IO->waitpid`. The *server* binds the Future::IO implementation —
`pagi-server` does this for you — so the same application runs unchanged under
any conforming PAGI server, whatever loop it is built on. Application code that
reaches for `IO::Async` directly gives that up.

**Handlers return applications.** `run_report` returns a `stream_response` on
the happy path and a `not_found` page for an unknown report. Both are ordinary
PAGI applications, so neither needs an adapter.

## Security note

The command table is fixed, and a request selects an entry by name. Request
data is never interpolated into a command. The list form of `open '-|'` also
avoids a shell entirely, so arguments are not word-split or glob-expanded — but
that is the second line of defence, not the first. If you adapt this example,
keep the allowlist.

## Requirements

- `Future::IO` and an implementation bound by your server (`pagi-server`
  configures `Future::IO::Impl::IOAsync` automatically when it is installed).
- A POSIX-ish platform: the list form of `open '-|'` forks, which Win32 does
  not support.
