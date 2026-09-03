# NDJSON Response and Streaming Extensibility Proof

**Date:** 2026-09-03

**Status:** Draft for review

**Scope:** Add a first-party newline-delimited JSON response implemented only
through the public `PAGI::Response::Stream` producer contract; expose one
structured, backpressured writer operation; document the streaming response
subclassing seam; and use the Starlette apples example as an end-to-end canary.

## 1. Decision

PAGI-Tools will add:

```text
PAGI::Response::NDJSON
PAGI::Response::NDJSON::Writer
ndjson_response(...)
```

The response uses the same construction model as the existing response
family:

```perl
use Future::AsyncAwait;
use PAGI::Response qw(ndjson_response);

return ndjson_response(
    async sub ($writer) {
        await $writer->write_item({ id => 1, name => 'Gala' });
        await $writer->write_item({ id => 2, name => 'Honeycrisp' });
    },
    headers => ['X-Export-Version' => 1],
);
```

The class form is canonical and equivalent:

```perl
return PAGI::Response::NDJSON->new(
    async sub ($writer) {
        await $writer->write_item({ id => 1, name => 'Gala' });
    },
);
```

`PAGI::Response::NDJSON` subclasses `PAGI::Response::Stream`. It adapts the
generic per-invocation `PAGI::Response::Writer` into a fresh
`PAGI::Response::NDJSON::Writer`. The specialized writer accepts Perl values
through `write_item`, encodes each value as one UTF-8 JSON text, appends one
newline byte, and delegates the resulting bytes to the generic Writer.

This is both a useful response type and an architectural proof. It must be
possible to implement the entire feature as a thin specialization of the
public Stream producer and Writer contracts. If it requires copied lifecycle
machinery, a new private Stream hook, or a special case in Response, Routing,
Compose, or the server, implementation stops and the response extensibility
design is reconsidered.

## 2. Work map

| Repository | Work item | Branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | NDJSON response and streaming extensibility proof | `feature/remove-mutable-router-frontends` | Current branch head `bbfaedd` and its existing PR against `main` | This design specification; after approval, NDJSON response/writer, exports, tests, response/cookbook documentation, and apples example | PAGI-Tools library and examples only; no PAGI or PAGI::Server changes | Existing branch and PR #28 |

The implementation plan must refresh this map before code work begins and
again before push. It must preserve unrelated changes already present in this
large worktree and add this campaign to the existing PR rather than create a
parallel branch.

## 3. Governing and superseded decisions

This design builds on the implemented response family and application-valued
Route endpoint work. The current source on this branch is authoritative for
the public `PAGI::Response::Stream` and `PAGI::Response::Writer` contracts.

It resolves the earlier `LATER-JSON-STREAM` deferral from the 2026-08-27 HTTP
response family design, but only for newline-delimited independent JSON texts.
It does not introduce an incrementally framed ordinary JSON array.

These existing decisions remain in force:

- a Request handler returns a PAGI application value;
- every Response is an application object through `to_app`;
- Stream owns response start, terminal close, cancellation, disconnect, and
  cleanup;
- every body write awaits the PAGI send Future and exposes real backpressure;
- a send pending at disconnect settles according to the PAGI 0.5 contract;
- Stream does not start a competing `$receive` loop;
- the producer is invoked afresh for every response application invocation;
- ordinary JSON object member order is unspecified;
- a Response stores no request-local Writer, scope, receive, send, or
  connection state; and
- a dedicated HEAD Route is the existing opt-out from running an expensive
  GET producer for HEAD.

## 4. Why this belongs in the first-party response family

NDJSON is a common transport for exporting or incrementally delivering a
sequence of independent structured records. Unlike a buffered JSON array, it
does not require retaining the complete collection or managing commas and a
closing delimiter across producer failures.

The NDJSON 1.0 specification requires every record to be an RFC 8259 JSON
text, encoded as UTF-8 and followed by `LF`; a JSON text may not contain raw
CR or LF. It recommends `application/x-ndjson` as the media type. See
<https://github.com/ndjson/ndjson-spec/blob/master/README.md>.

The feature also exercises the most important extension point in the new
Response model. Buffered subclassing has already been demonstrated by a
company collection JSON response that normalizes constructor input and
delegates to `PAGI::Response::JSON`. NDJSON tests the harder case: adding a
semantic streaming format without taking ownership of Stream's lifecycle.

Shipping the class is preferable to leaving only a cookbook sketch because:

- the format and media type are established;
- correct newline framing is easy to get subtly wrong;
- send-Future backpressure and disconnect cleanup are already toolkit
  responsibilities;
- a first-party implementation gives application authors one dependable
  vocabulary; and
- its implementation becomes executable evidence that the public streaming
  seam is sufficient.

## 5. Goals

The implementation must:

1. encode one Perl value as one UTF-8 JSON text followed by one `LF`;
2. preserve send-Future backpressure for every record;
3. create no hidden queue, prefetcher, complete-body buffer, or replay layer;
4. preserve Stream's existing normal, failure, cancellation, and disconnect
   lifecycle without copying it;
5. keep `undef` available as the ordinary JSON `null` value;
6. keep the producer in control of data acquisition and end-of-source policy;
7. prevent accidental raw-byte writes through the specialized writer;
8. support common Response status, header, content-type, application-value,
   and subclass-identity behavior;
9. remain reusable across response invocations;
10. document how an application author builds a comparable semantic Stream
    subclass using only public contracts; and
11. add a useful `/apples/export` canary to the Starlette comparison example.

## 6. Non-goals

This design does not:

- add an NDJSON parser or request-body decoder;
- implement RFC 7464 JSON Text Sequences or `application/json-seq`;
- stream one syntactically complete JSON array;
- sort object keys or promise canonical or byte-stable JSON;
- accept a cursor, iterator, arrayref, filehandle, or `next_item` source as the
  response constructor's first argument;
- interpret `undef` as end-of-stream;
- infer whether a value is already encoded JSON;
- expose raw `write`, `write_text`, `pipe_from`, or producer-owned `close`
  through the NDJSON Writer;
- add an encoder option, serializer registry, schema registry, or automatic
  object conversion;
- add batching, record compression, flushing controls, trailers, reconnect,
  retry, or keepalive behavior;
- change `PAGI::Response::Writer`, Stream lifecycle internals, the PAGI
  protocol, or PAGI::Server;
- teach Routing, Compose, RequestResponse, Pages, WebSocket, or SSE about
  NDJSON as a special case; or
- add the deferred `pipe_items($source)` convenience in version one.

A later `pipe_items` helper may adapt a deliberately specified item-source
protocol. It must remain layered on `write_item`; it must not replace the
producer callback as the fundamental construction model.

## 7. Public construction and export API

### 7.1 Constructor

```perl
PAGI::Response::NDJSON->new($producer, %response_options)
```

`$producer` must be a coderef. It receives one fresh
`PAGI::Response::NDJSON::Writer` for each invocation and may return an
immediate value or a Future. Stream retains responsibility for normal close,
producer cancellation, disconnect observation, and cleanup.

The supported response options are the inherited common options:

```text
status
headers
content_type
```

They retain the base Response validation, including duplicate, odd, unknown,
or malformed option diagnostics. The constructor must pass the option list to
`SUPER::new` without re-parsing or normalizing it independently.

The default content type is:

```text
application/x-ndjson
```

An explicit `content_type` remains possible and uses the normal Response
setter contract. NDJSON does not calculate Content-Length. An explicitly
supplied Content-Length header is retained as the application's delivery
promise, matching Stream.

Constructor dispatch through `SUPER::new` must preserve the invoked subclass:

```perl
package MyApp::AuditExport;
use parent 'PAGI::Response::NDJSON';

my $response = MyApp::AuditExport->new($producer);
ref($response) eq 'MyApp::AuditExport';
```

The NDJSON constructor may adapt the producer, but it must not capture an
active Writer, scope, receive/send callback, or connection object.

### 7.2 Factory

```perl
use PAGI::Response qw(ndjson_response);

my $response = ndjson_response($producer, %response_options);
```

`ndjson_response` always constructs `PAGI::Response::NDJSON`. It is:

- exported optionally by `PAGI::Response`;
- included in `PAGI::Response`'s `:all` bundle; and
- the sole optional export of `PAGI::Response::NDJSON`.

It is not exported by default and does not inspect the caller to select an
application subclass.

### 7.3 Application value

NDJSON inherits Stream's `to_app` behavior and is a normal application-valued
Response:

```perl
async sub export_people($request) {
    return ndjson_response(async sub ($writer) {
        for my $person (@{$people->all}) {
            await $writer->write_item($person);
        }
    });
}

route('/people/export' => \&export_people, methods => ['GET']);
```

It may also be preconstructed and used as an object endpoint when the producer
is intentionally request-independent. Like every Stream, it is HTTP-only as a
standalone `to_app` application and depends on Router/Compose for the normal
root safety boundaries.

## 8. NDJSON Writer contract

### 8.1 Purpose and ownership

`PAGI::Response::NDJSON::Writer` is a per-invocation format facade over the
generic `PAGI::Response::Writer`. It is not a Response, application value,
constructor argument, source iterator, or independently deployable object.
Application producers receive it from NDJSON and do not construct it.
It is a public producer-facing support type, not a promised subclassing base;
authors of another streaming format may define their own facade over the
generic Writer.

The implementation may hold the generic Writer as one private delegate. It
must not copy that Writer's mutable state, reconstruct transport or connection
objects, or invoke its private methods.

### 8.2 Public methods

The specialized writer exposes exactly:

```text
write_item($value)       -> Future
on_close($callback)      -> self
is_closed()              -> Bool
is_disconnected()        -> Bool or undef
disconnect_reason()      -> String or undef
bytes_written()          -> nonnegative integer
buffered_amount()        -> nonnegative integer
high_water_mark()        -> nonnegative integer or undef
low_water_mark()         -> nonnegative integer or undef
is_writable()            -> Bool
on_high_water($callback) -> self
on_drain($callback)      -> self
```

All methods other than `write_item` delegate to the corresponding public
generic Writer method. Chainable methods return the NDJSON Writer, not the
underlying generic Writer. Their absence behavior and meanings remain those
of the generic Writer, including:

- `is_disconnected` returns `undef` without a connection capability;
- `buffered_amount` returns zero without transport introspection;
- watermarks return `undef` without transport introspection;
- `is_writable` returns true without a high-water mark; and
- high-water/drain registrations are quiet chainable no-ops when unsupported.

`bytes_written` counts encoded bytes accepted while still connected,
including each record's terminating `LF`. It does not mean bytes received by
the client.

The specialized writer deliberately does not expose:

```text
write
write_text
pipe_from
close
```

This prevents a producer from bypassing record encoding or injecting bytes
that violate the NDJSON format. Returning normally from the producer asks
Stream to perform the terminal close. Returning early is the normal way to
finish early.

### 8.3 `write_item`

```perl
my $future = $writer->write_item($value);
await $future;
```

For each call, `write_item`:

1. JSON-encodes the supplied Perl value directly to UTF-8 bytes;
2. appends exactly one `LF` byte (`0x0A`);
3. calls the generic Writer's public `write($bytes)` exactly once; and
4. returns that exact delivery Future without resolving early or placing it
   behind another queue.

The producer must await one call before starting another. The generic Writer
continues to enforce its one-outstanding-write rule.

`undef` is a valid value and encodes as:

```text
null\n
```

This is why EOF is not part of `write_item`. The producer owns iteration and
decides when to return.

Encoding errors croak synchronously before a body send is attempted, matching
the generic Writer's synchronous validation behavior. In an async producer,
that exception fails the producer Future and enters Stream's existing
post-start failure cleanup. If encoding succeeds but the PAGI send fails, the
returned write Future fails according to the generic Writer contract.

## 9. Encoding and wire format

The default encoder follows `PAGI::Response::JSON`'s policy:

```perl
JSON::MaybeXS->new(utf8 => 1)
```

The class may retain one package-local encoder. It does not turn on canonical
key ordering, pretty printing, relaxed parsing, or nonstandard scalar support.
Object member order is unspecified.

Every successful `write_item` emits one nonempty NDJSON record. JSON escaping
ensures character data containing CR or LF appears as JSON escape sequences,
not raw record delimiters. The implementation appends `LF`, not `CRLF`, and
does not emit blank lines.

A producer that writes no items yields a valid empty NDJSON body: Stream still
sends response start and its normal terminal empty body event, but NDJSON adds
no blank record.

Examples:

```text
Perl input                         Wire bytes
--------------------------------  -------------------------------
{ id => 1, name => 'Gala' }       {"id":1,"name":"Gala"}\n
undef                             null\n
"first\nsecond"                   "first\nsecond"\n
```

The third row's line break is escaped within the JSON string on the wire; only
the final byte is a literal newline delimiter.

Encoding occurs per item immediately before its write. NDJSON does not
pre-encode future records and does not retain previously encoded records.

## 10. Backpressure, disconnects, and cleanup

`write_item` is the record-level backpressure boundary:

```perl
await $writer->write_item($record);
```

The implementation must not wrap the generic Writer Future in an already-done
Future, schedule another record before it settles, or create a queue between
encoding and send. A producer that awaits each item cannot outrun the server's
outbound buffering policy.

The producer controls source acquisition, so bounded pull-through is natural:

```perl
return ndjson_response(async sub ($writer) {
    my $cursor = await $database->people_cursor;
    $writer->on_close(sub { return $cursor->close });

    while (!$writer->is_disconnected) {
        my $person = await $cursor->next_item;
        last unless defined $person;
        await $writer->write_item($person);
    }
});
```

The cursor example uses `undef` as that particular cursor's EOF convention.
It does not change `write_item(undef)`, which always means JSON `null`.

NDJSON starts no receive loop and adds no disconnect race. The generic Writer
and Stream remain authoritative:

- a send pending at disconnect resolves after the server finishes with the
  event;
- discarded bytes are not counted;
- the producer observes disconnect on its next state check, while Stream's
  connection signal may cancel producer-owned work waiting elsewhere;
- Stream never cancels a server-owned send Future;
- genuine producer or send errors propagate;
- normal producer completion sends the terminal empty body event; and
- registered cleanup runs once in registration order on normal completion,
  failure, cancellation, or disconnect.

An encoding failure can occur only after Stream has already sent response
start. Records successfully written before that failure may have been
accepted. Stream runs cleanup and propagates the error; ErrorHandler cannot
replace a partially emitted response with a new 500. The documentation must
state this as an ordinary streaming property, not imply transactional output.

## 11. Reuse, mutation, and subclassing

One NDJSON Response stores response configuration and one producer coderef.
It does not store an invocation's specialized writer. Every `to_app`
invocation receives:

- a fresh generic Writer from Stream;
- a fresh NDJSON Writer wrapping it; and
- a fresh call to the producer.

An unchanged response can therefore serve concurrent requests. As with
Stream, a producer that closes over mutable or one-shot state owns that normal
application concurrency decision:

```perl
# Deliberately one-shot and therefore unsuitable for concurrent reuse.
my $cursor = $database->cursor;
my $response = ndjson_response(async sub ($writer) {
    ... use $cursor ...
});
```

The framework does not clone, reset, snapshot, or defensively copy captured
application state.

Application subclasses may validate semantic constructor input and then
delegate a completed producer plus the untouched response options to
`SUPER::new`, just as buffered semantic subclasses already do. They must not
override Stream's private lifecycle or emission methods.

The Cookbook must include a compact explanation of the implementation shape:

```perl
package MyApp::RecordStream;
use parent 'PAGI::Response::Stream';

sub new {
    my ($class, $producer, @response_options) = @_;
    my $adapted = sub {
        my ($generic_writer) = @_;
        my $format_writer = MyApp::RecordWriter->new($generic_writer);
        return $producer->($format_writer);
    };
    return $class->SUPER::new($adapted, @response_options);
}
```

The complete recipe must show a format writer delegating only public generic
Writer methods. It should use NDJSON as the concrete, shipped example rather
than invent another near-identical wire format.

## 12. Route, HEAD, and protocol boundaries

### 12.1 Route use

A normal one-Request handler returns the NDJSON Response directly:

```perl
async sub export_apples($request) {
    my $items = apples($request)->all;

    return ndjson_response(async sub ($writer) {
        for my $apple (@$items) {
            last if $writer->is_disconnected;
            await $writer->write_item($apple);
        }
    });
}
```

No `request_response`, `as_app_object`, `invoke_app`, raw PAGI closure, or
Route special case is required.

### 12.2 HEAD

NDJSON inherits Stream's HEAD behavior. The enclosing Router/Compose HEAD
boundary suppresses body bytes, but the GET producer still runs so middleware
sees equivalent GET and HEAD behavior. That may be expensive.

Authors who need a cheaper HEAD path declare it before the GET route:

```perl
route('/export' => \&head_export, methods => ['HEAD']);
route('/export' => \&export,      methods => ['GET']);
```

This design adds no constructor flag that changes the shared HEAD policy.

### 12.3 Protocol-response capability

NDJSON emits only ordinary body events and therefore inherits Stream's
`body-events-v1` protocol-response capability. It adds no special WebSocket or
SSE code. A producer used for a protocol denial or decline must be finite and
appropriate for that boundary; an unbounded export producer would be
application misuse.

## 13. Apples canary

The runnable `examples/starlette-apples` application gains a useful export
without changing the original Python source preserved in its README:

```perl
use PAGI::Response qw(file_response json_response ndjson_response);

async sub export_apples($request) {
    my $items = apples($request)->all;

    return ndjson_response(async sub ($writer) {
        for my $apple (@$items) {
            last if $writer->is_disconnected;
            await $writer->write_item($apple);
        }
    });
}

mount('/apples',
    routes => [
        route('/' => \&list_apples,
            methods => ['GET'], name => 'list'),
        route('/' => \&create_apple,
            methods => ['POST'], name => 'create'),
        route('/export' => \&export_apples,
            methods => ['GET'], name => 'export'),
        route('/{apple_id:&Int}' => \&read_apple,
            methods => ['GET'], name => 'read'),
        # update and delete remain unchanged
    ],
    name       => 'apples',
    middleware => [middleware(\&with_apples_api_header)],
);
```

The response body for the initial fixture is two records:

```text
{"id":1,"name":"Gala","color":"Red/Yellow"}
{"id":2,"name":"Honeycrisp","color":"Rosy Red"}
```

Object key order is not asserted. Tests decode each nonempty line and compare
the resulting values.

The integration test must also establish that:

- status is 200;
- Content-Type is `application/x-ndjson`;
- exactly two newline-terminated records are returned;
- the global request-ID middleware still applies;
- the `/apples` mount middleware still adds `X-Apples-API: 1`;
- HEAD returns no wire body; and
- the existing CRUD behavior and original Python checksum remain unchanged.

The README explains that `/apples/export` is an intentional PAGI extension,
not a route present in the preserved Starlette source, and gives a runnable
`curl` example.

## 14. Documentation changes

The implementation updates:

- `PAGI::Response`'s class/factory table, `:all` count, memory/delivery
  discussion, subclassing links, and factory documentation;
- new complete POD for `PAGI::Response::NDJSON`;
- new complete POD for `PAGI::Response::NDJSON::Writer`;
- `PAGI::Response::Stream` to name semantic producer/writer adaptation as the
  supported streaming subclass seam while keeping lifecycle internals private;
- `PAGI::Response::Writer` to cross-link the structured NDJSON facade and
  retain the distinction between byte `write` and source `pipe_from`;
- `PAGI::Tools::Cookbook` with a "Streaming Response Extension: NDJSON"
  recipe showing the public-only implementation pattern;
- `examples/starlette-apples/app.pl` and its README;
- the example index where its description benefits from mentioning the
  streaming export;
- the relevant upgrading/development notes only if the implementation changes
  an already documented extension statement; and
- `Changes`, describing NDJSON as a new response type and public streaming
  extensibility proof.

Documentation must distinguish:

```text
$writer->write($bytes)       generic encoded-byte chunk
$writer->pipe_from($source)  generic next_chunk byte source
$writer->write_item($value)  one encoded NDJSON record
```

It must not imply that generic Writer accepts `next_chunk` objects through
`write`, or that NDJSON Writer accepts raw bytes.

## 15. Error handling and diagnostics

Construction fails synchronously when:

- the producer is absent or is not a coderef; or
- common Response options are unknown, duplicate, odd, or malformed.

`write_item` fails synchronously before calling the generic Writer when the
value cannot be encoded by the documented JSON encoder. Its diagnostic must
retain the encoder's useful cause and identify NDJSON item encoding rather
than falsely reporting a PAGI send failure.

After encoding, generic Writer diagnostics and Future outcomes remain
unchanged:

- a second outstanding write croaks;
- a write after close returns the existing failed Future;
- a failed or cancelled send follows the existing Writer contract; and
- disconnect itself does not manufacture a failed write under PAGI 0.5.

No NDJSON error path sends a replacement response after response start.

## 16. Required verification outcomes

The implementation plan must use test-driven development and cover these
outcomes without duplicating the entire Stream suite.

### 16.1 Construction and API

- class and factory construction return `PAGI::Response::NDJSON`;
- subclass construction preserves subclass identity;
- default and explicit content types behave through inherited Response rules;
- status and ordered headers are preserved;
- malformed producers and options fail at construction;
- the factory is opt-in, present in `:all`, and exported by the concrete class;
- the specialized Writer has the documented methods and does not expose raw
  emission or close methods; and
- each invocation receives a distinct specialized Writer.

### 16.2 Encoding and framing

- hashes, arrays, strings, numbers, booleans, and `undef` encode as valid JSON;
- every item receives exactly one trailing `LF`;
- `undef` produces `null\n` and never terminates the producer;
- embedded CR/LF characters remain escaped inside the JSON text;
- no blank records or `CRLF` delimiters are introduced;
- non-ASCII input emits UTF-8 bytes;
- object member order is not contracted by tests; and
- an unsupported value identifies an NDJSON encoding failure and sends no
  body event for that item.

### 16.3 Streaming behavior

- `write_item` delegates one item to exactly one generic write;
- its returned Future remains pending while the underlying send Future is
  pending and settles with that delivery;
- a second item cannot begin while the first write remains outstanding;
- byte counts include successful encoded records and their delimiters;
- producer failure, cancellation, disconnect, and normal completion retain
  existing Stream cleanup behavior;
- cleanup runs exactly once;
- a pending send at disconnect follows the current PAGI settlement contract;
- response reuse invokes the producer again with fresh writers; and
- concurrent invocations do not share writer state.

Focused NDJSON tests should reuse existing PAGI Test connection/transport
fixtures. The implementation must not clone Stream tests merely to obtain a
larger test count.

### 16.4 Integration and documentation

- a Request handler returns NDJSON through an ordinary Route;
- the PAGI Test Client captures and decodes `/apples/export` as two records;
- global and mount middleware headers remain present;
- HEAD suppresses the body while preserving response headers;
- the original Python example remains byte-for-byte unchanged;
- runnable POD and Cookbook snippets compile where the repository already
  provides snippet checks; and
- distribution/load checks include both new modules.

### 16.5 Extensibility gate

Review the implementation source directly and fail the campaign review if it:

- calls a private method on `PAGI::Response::Stream` or
  `PAGI::Response::Writer`;
- copies `_run_lifecycle`, cancellation arbitration, disconnect signaling,
  close, cleanup, or send-settlement code;
- changes Stream/Writer internals solely to admit NDJSON;
- adds an NDJSON condition to Response, Routing, Compose, protocol handlers,
  or PAGI::Server;
- introduces a queue, prefetch loop, hidden cache, or body replay; or
- needs defensive cloning of application values or captured producer state.

A simple cross-link or general clarification in Stream/Writer POD is not an
internal change. A missing public capability is. If one is discovered,
implementation pauses and reports the exact missing seam for design review.

## 17. Adversarial review and rejected alternatives

### 17.1 Accept a `next_item` source directly

Rejected for the foundational constructor. It is concise for cursors but
makes `undef` ambiguous between JSON `null` and EOF, makes one-shot source
reuse unsafe, and requires the toolkit to invent source cleanup and
cancellation conventions. A source factory repairs reuse but approaches the
producer callback with a narrower vocabulary.

The producer form can already consume any application cursor explicitly and
register its cleanup. A later `pipe_items` convenience can be considered once
there is a concrete shared source protocol.

### 17.2 Pass a bare emitter coderef

Rejected. `await $emit->($value)` is initially concise but has nowhere to put
disconnect state, cleanup, byte counts, or flow-control observation. Adding
extra callback arguments or callable-object attributes recreates Writer less
clearly. The specialized Writer makes the capability boundary explicit.

### 17.3 Overload generic `write`

Rejected. A generic Writer `write` accepts bytes. Making it sometimes encode
references would couple HTTP streaming to JSON, make blessed/scalar values
ambiguous, and weaken the byte boundary used by other formats. `write_item`
names the semantic operation.

### 17.4 Expose raw methods on the specialized writer

Rejected. Raw `write`, `write_text`, and `pipe_from` would permit invalid
records and make the class unable to promise NDJSON framing. A producer that
needs mixed or raw output should use `stream_response` directly.

### 17.5 Buffer a complete array and return JSON

Rejected as a substitute. `json_response($items)` is correct when the complete
collection is finite and should be buffered. It does not provide incremental
delivery, bounded producer memory, or record-level backpressure.

### 17.6 Canonical JSON

Rejected as the default. Stable key order has CPU cost and is not part of the
existing JSON response contract or NDJSON framing requirement. An application
that signs or hashes records needs a deliberately canonical response class.

### 17.7 Implement NDJSON inside Stream

Rejected. Format knowledge in generic Stream would repeat the all-purpose
Response design being removed. NDJSON must prove that composition and
subclassing are enough.

## 18. Implementation sequencing constraints

The later implementation plan should separate these reviewable stages:

1. NDJSON construction, encoding, writer facade, and focused red/green tests;
2. backpressure, disconnect, cleanup, reuse, and concurrency verification;
3. exports and response-family documentation;
4. Cookbook public-extensibility recipe;
5. apples canary and its focused integration tests; and
6. final scoped verification, design comparison, work-map update, commit, and
   existing-PR update.

The plan must not run the entire suite after every small documentation or
example edit. Use focused tests while developing, then the repository's full
required verification once at the final integration boundary. If unrelated
tests fail because this large worktree is temporarily half-translated, inspect
and report that evidence rather than hiding it; failures related to NDJSON,
Response, Routing, or the apples canary must pass before completion.

## 19. Completion criteria

This campaign is complete only when:

- the public API and wire contract above are implemented;
- NDJSON is a thin public-API specialization of Stream;
- no lifecycle or send-settlement code is duplicated;
- focused unit and apples integration tests pass;
- documentation gives complete class, factory, Route, backpressure, cleanup,
  HEAD, failure, and extension examples;
- the original Starlette source remains intact;
- the implementation is compared back to this design and any deviation is
  explicitly recorded; and
- the current branch and PR contain the complete reviewed result.

The key qualitative gate is visible in the code: the implementation should be
short, unsurprising, and obviously defer lifecycle ownership to Stream. If it
is not, the feature has found a flaw in the response design rather than a
reason to add another workaround.
