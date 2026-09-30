# Header helpers and consumer migration

Date: 2026-09-21

Status: consolidated design for review. The main API choices and migration scope
were approved in discussion. Runtime implementation has not started.

Research and decision history:
[Header helpers API research](../audits/2026-09-21-header-helpers-api-research.md).

## Purpose

Make common header operations straightforward without moving application policy
into header parsing. Auth backends should not repeat Authorization regexes;
multipart readers should share parameter parsing; middleware should compose Vary;
file responses should compare ETags correctly.

Keep `PAGI::Headers`. Add public value utilities and convenient instance methods,
then migrate existing consumers and their documentation/examples to use them.
The public raw operations remain available for custom fields and interpretations.

This is a PAGI-Tools design, not a change to the PAGI protocol or a dependency on
PAGI::Server internals. Work remains on the current working branch.

## Architecture and boundaries

- `PAGI::Utils::Headers` owns synchronous, independent value functions, exported
  only on request. They have no Request/scope/app dispatch or I/O.
- `PAGI::Headers` owns field lookup and multiplicity, delegating value parsing.
- Existing Request shortcuts delegate to Headers. Avoid a second parser there.
- Consumers own credential verification, application failures, response status,
  resource existence and conditional-request decisions.

Keep the current ordered-pair container contract: case-insensitive field lookup,
original casing/order, separate duplicates, and no automatic comma-joining by
`get`. `get` remains last-value lookup. Raw values remain opaque; this work does
not change server-owned response emission validation.

Parsers return ordinary Perl data. Their results are parsed values, not views
that write back into Headers. Mutating such a result does not modify the stored
field; use `set`/`add` and a formatter to write a new field. No parsed-value cache
or mutation-observer machinery is needed. References follow ordinary Perl aliasing.

Headers read methods do not rewrite fields. Mutating conveniences return the
Headers instance, consistent with `set` and `add`.

## Shared calling and error contract

Parser `%opts` accepts `raise_on_error => $boolean`, false by default. Both modes
recognize the same syntax. A malformed value returns undef by default and raises
a descriptive exception when requested. Basic has a list return and uses
`(undef, undef)`. Missing input is not an error in either mode.

List APIs distinguish an absent field from a present empty list as specified
below. Membership predicates return false for unusable input; their exception
option still reports malformed input. Unknown options, wrong argument shapes,
and invalid formatter arguments are programming errors regardless of this option.

Exceptions identify the operation and problem without echoing credentials.
They are ordinary exceptions, not HTTP responses or a new exception hierarchy.
No global last-error state is introduced.

Except for the filename character input described below, values are HTTP byte
strings. Do not infer text encodings. Compare protocol identifiers with ASCII
folding where appropriate. Surrounding optional whitespace means SP/HTAB, not
arbitrary Perl Unicode whitespace. Formatters produce byte strings suitable for
ordinary response headers and reject values outside their supported syntax.

The Basic APIs are documented and demonstrated in list context. Do not introduce
a separate scalar-context object or joined-credential contract.

## API: single fields and authentication

### Independent functions in PAGI::Utils::Headers

```perl
my $token = parse_authorization_bearer($value, %opts);
my ($username, $password) = parse_authorization_basic($value, %opts);
my $challenge = www_authenticate($scheme, @parameter_pairs);
```

Both parsers accept a single value or undef. Missing input and an identifiable
other scheme produce no credentials. Malformed supported credentials follow the
error contract. Scheme recognition is case-insensitive.

Bearer returns the opaque token; it does not decode or verify it. Basic validates
Base64 and the username/password separator, returns bytes, and splits at the
first colon. Empty username/password are values; forbidden control characters
are not accepted. Character decoding belongs to the application.

Use the field syntax in [RFC 6750 §2.1](https://www.rfc-editor.org/rfc/rfc6750.html#section-2.1)
and [RFC 7617 §2](https://www.rfc-editor.org/rfc/rfc7617.html#section-2).
Accept conventional valid padded Base64; do not use permissive decoding alone
as proof of valid Basic credentials or repair malformed input first.

`www_authenticate` becomes the canonical implementation of the existing formatter:
one scheme and ordered parameter pairs, quoted/escaped parameter values, one
plain challenge value. Preserve its current validation and documented limitation:
it does not implement scheme-specific serialization such as unquoted Digest
parameters. Keep `PAGI::Auth::www_authenticate` as a delegate with its existing
exported/class/instance invocation and override behavior.

### Headers methods

```perl
my $value = $headers->get_single($name, %opts);
my $token = $headers->authorization_bearer(%opts);
my ($username, $password) = $headers->authorization_basic(%opts);
```

`get_single` returns the raw value only when exactly one occurrence exists.
Zero occurrences return undef; multiple occurrences are malformed even when
identical. It does not trim or validate the one value. The caller explicitly
chooses singleton semantics; there is no registry that changes raw `get`.

The Authorization methods examine every occurrence before selecting a value.
They never choose credentials from duplicate fields. One missing field or
another identifiable scheme is not an exception; duplicates are, when requested.

### Request shortcuts

```perl
my $token = $request->bearer_token(%opts);
my ($username, $password) = $request->basic_auth(%opts);
```

These retain their names and delegate to the Headers methods above. Their former
permissive parsing is replaced by the agreed shared recognition rules. Document
that behavior change; do not retain an undocumented alternative parser.

## API: parameterized values

### Independent functions

```perl
my $parsed = parse_header_parameters($value, %opts);
# { value => $leading_value, parameters => [name, value, ...] }

my $value = format_header_parameters($leading_value, @parameter_pairs);
my $quoted = quote_header_value($value);
```

The parser reads one leading value with semicolon-separated parameters. It is
not a general comma-list or authentication-challenge parser. It handles quoted
values and escapes, preserving value bytes, parameter order, and duplicate
names. Normalize parameter names with ASCII folding. Do not decode extended
parameters or percent escapes automatically.

The leading value must be nonempty after surrounding whitespace is removed.
Field-specific interpretation of it belongs to the named methods. Empty
semicolon slots may be skipped; a parameter with missing `=`/value, bad quoting,
or leftover malformed syntax makes the whole parse unusable. A quoted empty
value is valid. Do not return a silently repaired partial parse.

The formatter preserves supplied parameter order, emits token values where
possible, and quotes/escapes other supported byte values. Its leading value is
an already-selected field value, not an arbitrary header fragment: reject control
bytes and delimiter injection. It may retain repeated parameter names so callers
can work with grammars beyond the named field conveniences.

`quote_header_value` always returns a quoted-string, escaping quotes/backslashes.
It rejects bytes invalid in that grammar; it does not quote ETags or encode text.

### Headers and Request

```perl
my $type = $headers->content_type(%opts);
my $parameters = $headers->content_type_parameters(%opts);
my $disposition = $headers->content_disposition(%opts);
my $parameters = $headers->content_disposition_parameters(%opts);
```

These methods require a single field, validate its leading media type/disposition
token, and return the normalized leading value or parameter hash respectively.
A valid field with no parameters has `{}` as its parameter hash. Missing or
malformed input yields undef. The exception option reports malformed input.

Case-insensitive duplicate parameter names are treated as unusable by these
named conveniences; do not silently select a winner. This is PAGI's explicit
handling choice, not a claim about every possible parameterized field grammar.
Unknown parameter names remain available. `filename` and `filename*` are distinct;
the latter retains its encoded parameter value in this lexical read API.

Request's existing `content_type` shortcut delegates but retains its documented
empty-string fallback. It accepts the exception option. Audit its internal
callers for normalization and missing-value behavior.

### Response filenames

```perl
my $value = content_disposition($disposition, @parameter_pairs);

use utf8;
content_disposition('attachment', filename => 'résumé.pdf');
# attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf
```

This response-oriented formatter validates the disposition token and unique
parameter names. For `filename`, accept a Perl character string: ASCII uses a
quoted filename parameter; non-ASCII uses UTF-8 extended encoding. Callers with
encoded text decode it first. Do not guess an encoding or invent an ASCII
transliteration/fallback. Other ordinary parameters use shared quoting.
Filename control characters rejected by the existing File API remain invalid;
this helper does not perform filesystem filename sanitization.

An explicitly supplied `filename*` is a preformatted ASCII extended value,
emitted without quoted-string wrapping after syntax validation. It can accompany
an ASCII `filename` fallback. Reject a non-ASCII filename that would generate a
second `filename*`. This preserves an explicit escape route without adding
fallback-generation options.

`file_response($path, filename => $filename)` uses this function internally.
Raw field construction remains available for other encodings or schemes.

Download rules are defined by [RFC 6266](https://www.rfc-editor.org/rfc/rfc6266.html#section-4.3)
and [RFC 8187](https://www.rfc-editor.org/rfc/rfc8187.html). Multipart upload
interpretation remains separate; it does not acquire response `filename*`
handling. [RFC 7578 §4.2](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.2)

## API: token lists and Vary

```perl
my $tokens = parse_header_tokens($value, %opts);
my $tokens = $headers->tokens($name, %opts);
my $present = $headers->has_token($name, $token, %opts);

my $value = merge_vary($existing_values, @field_names);
$headers->add_vary(@field_names);
```

Token parsing returns an arrayref in input order with spelling and duplicates
preserved. Missing input/fields and empty lists produce `[]`. Ignore empty list
members; reject malformed nonempty members through the shared error contract.
Headers combines all occurrences only because the caller chose token-list
interpretation. Quoted strings, parameterized members, dates and cookies are
outside this token-list grammar.

`has_token` defaults to exact comparison; `case_insensitive => 1` requests ASCII
case-insensitive membership. It also accepts `raise_on_error`. Absence, an empty
list or a malformed list in default mode produces false. Parsing does not change
case or deduplicate simply because comparison is insensitive.

`merge_vary` accepts an arrayref of existing field values and additional field
names. It returns one merged value, preserving first spelling/order, deduplicating
case-insensitively and reducing any wildcard-containing result to `*`. All supplied
new names must be field-name tokens or `*`. An empty input produces an empty string.
Malformed existing nonempty members raise rather than silently losing a cache
dependency. This is a formatter/composition function, not an optional read parser.

`add_vary` reads all current Vary values, calls `merge_vary`, and replaces those
occurrences with the merged field. It leaves unrelated fields intact and returns
the Headers instance. With no current values or added names it is a no-op.

Pages, CORS and GZip share this implementation. Pages can use the pure function
with its flat-list extraction/replacement code; no public header-list convention
changes. `Set-Cookie` is never routed through these helpers.

## API: entity tags

```perl
my $tag = parse_etag($value, %opts);
# { value => $opaque_bytes, weak => 0|1 }
my $value = format_etag($opaque_bytes, weak => $boolean);

my $condition = parse_etag_list($field_values, %opts);
# { any => 0, tags => [ $tag, ... ] }
# or { any => 1, tags => [] }

my $matches = etag_matches($condition, $current_etag, weak => $boolean);

my $tag = $headers->etag(%opts);
my $condition = $headers->if_none_match(%opts);
my $condition = $headers->if_match(%opts);
```

`parse_etag` handles one field value. `format_etag` accepts the unquoted opaque
value and defaults to strong form. It rejects invalid contents instead of
quoted-string escaping them. `etag` requires one ETag occurrence.

`parse_etag_list` takes an arrayref of field values in received order. An empty
array means absence and returns undef. A present empty list produces
`{ any => 0, tags => [] }`. Preserve order/repeats in the tags array. Wildcard
must stand alone rather than be mixed with tags. Both conditional field methods
read every occurrence; syntax errors follow the error contract.

`etag_matches` takes a parsed condition and a valid current wire-format ETag.
An absent condition returns false; invalid current-tag arguments are programming
errors. Default comparison is strong; `weak => 1` ignores the strength markers
when comparing opaque values. A wildcard condition matches when a valid current
tag is supplied. It cannot infer existence from a missing tag: callers handling
representations without ETags inspect `any` and their own resource state.

Parsing must keep commas inside tags and must not apply quoted-string unescaping.
Use the tag syntax and comparison definitions in
[RFC 9110 §8.8.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.8.3).
No ETag class, persistent parsed view, or general precondition engine is added.

## Required consumer behavior

### Bearer examples and docs

The main JWT sandbox and Notes examples distinguish presentation failures from
token verification failures with `raise_on_error => 1`:

```perl
my $token;
my $parsed = eval {
    $token = $request->bearer_token(raise_on_error => 1);
    1;
};
return unauth_result(failure => {
    code => 'malformed_authorization',
    message => 'Supply one correctly formed Bearer credential.',
}) unless $parsed;
return unauth_result() unless defined $token;

# Existing token verification follows, outside this parsing exception handler.
```

The example response policy is:

| Situation | Status | Bearer challenge error parameter |
| --- | --- | --- |
| Missing credentials/unsupported scheme | 401 | Omitted |
| Malformed presentation, including duplicates | 400 | invalid_request |
| Rejected token, including malformed JWT | 401 | invalid_token |
| Insufficient token privileges | 403 | insufficient_scope |

Follow [RFC 6750 §3.1](https://www.rfc-editor.org/rfc/rfc6750.html#section-3.1)
and the challenge requirement in
[RFC 9110 §15.5.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.5.2).
Application failure codes remain application conventions. These examples do not
add automatic responses to Auth or Headers.

Also document the shorter default form for callers deliberately treating unusable
credentials as absent, with its different diagnostic behavior clearly stated.
All examples use `defined` rather than token/username truthiness.

### File and conditional-response matching

Replace exact-first-field comparison in File::Plan and ad hoc comma splitting
in ConditionalGet with shared parsing and weak If-None-Match comparison for
GET/HEAD representation responses. Include repeated fields, wildcard and tags
containing commas. Wildcard uses known representation existence, including an
existing selected file whose ETag generation is disabled.

A matching conditional GET/HEAD selects a bodyless 304 only when the underlying
response is eligible for conditional handling; do not convert errors or redirects.
Do not generate 304 for other methods. This project does not add conditional
write enforcement or claim to implement every precondition.

Evaluate supported conditions before range delivery; retain selected-file/window
identity and generation policy. A nonmatching condition continues existing range
handling. Preserve validators and required metadata in the 304 response.

ConditionalGet must not use If-Modified-Since as a fallback when If-None-Match is
present, even when there is no current ETag or the condition is unusable. Default
consumer handling of malformed If-None-Match is to ignore its condition, never
match a partially recovered tag. File does not gain date or If-Range support.
[RFC 9110 §13](https://www.rfc-editor.org/rfc/rfc9110.html#section-13)

### Parameter and Vary consumers

Both multipart readers use the parameter parser for disposition metadata. Both
Request multipart entry points use shared Content-Type parameter parsing for
boundary extraction. Keep their existing streaming, body ownership, size limits
and character interpretation responsibilities. Unknown multipart parameters stay
available; a `filename*` parameter does not become `filename` automatically.

File response disposition formatting uses the new response helper. Pages, CORS
and GZip use common Vary merging. Headers `dehop` may reuse token parsing while
retaining Connection-nominated removal. Malformed Connection syntax must not
silently erase every usable nomination: retain its current handling unless a
separate behavior correction is justified in review.

## Migration and documentation inventory

| Area | Files/coverage |
| --- | --- |
| New utilities and Headers | `lib/PAGI/Utils/Headers.pm`, `lib/PAGI/Headers.pm`, focused utility tests, `t/headers.t` |
| Request | `lib/PAGI/Request.pm`, `t/request/05-auth.t`, multipart entry-point tests |
| Multipart | `lib/PAGI/Request/MultiPartHandler.pm`, `MultipartStream.pm`, buffered/streaming metadata regressions |
| File responses | `lib/PAGI/Response/File.pm`, `File/Plan.pm`, `t/response/04-file.t`, relevant App::File/Static tests |
| Conditional responses | `lib/PAGI/Middleware/ConditionalGet.pm`, `ETag.pm`, `t/middleware/conditional-get.t` |
| Vary | `lib/PAGI/Pages.pm`, `Middleware/CORS.pm`, `Middleware/GZip.pm`, their existing test families |
| Auth formatter | `lib/PAGI/Auth.pm`, `t/auth/07-www-authenticate.t`; retain invocation/override coverage |
| Auth examples | `examples/auth-jwt-sandbox/{app.pl,app2.pl,README.md}`, `examples/auth-notes/{app.pl,README.md}`, relevant `auth-extensions` examples/README |
| Public guidance | Headers/Utils/Request/Auth/Response/File POD, `lib/PAGI/Tools/Cookbook.pod`, `Tutorial.pod`, release notes |

Inspect remaining call sites with repository searches during planning. Historical
specs and handoffs remain history; link this successor instead of rewriting them.

Each public function/method needs exact arguments, return shape, absence/empty/
malformed behavior, mutation behavior and an example. Explain independent utility
usage, Request delegation and raw field alternatives. Mark intentionally bounded
formatters, including the existing WWW-Authenticate behavior.

Documentation must cover all four motivating cases: authentication extraction,
download/upload parameters, middleware Vary composition and conditional GET.
Prefer several small examples to one application with unrelated features. Do not
add a browser exercise or a large new example test suite for this utility work.

## Implementation and verification constraints

Use existing Base64 facilities, core Encode for UTF-8 filename encoding, and the
already-declared HTTP::Date where dates are needed. Do not add HTTP-Message or
Mojolicious solely to wrap parsing that must then be reimplemented for this
contract. Shared internal scanning must stay focused on the supported grammars.
No public parser registry, live-view objects or compatibility-mode matrix.

Meaningful verification includes:

- Both error-reporting modes; absent, empty and malformed cases; wrong argument
  shapes; valid zero/empty credential components and duplicate Authorization.
- Basic decoding/separator/control rules; colon-containing passwords; supported
  schemes versus unknown schemes; Request/Headers/function agreement.
- Quoted delimiters/escapes, empty parameter values, duplicate/case handling,
  complete-input failures and unknown parameters. Buffered/streaming parity.
- ASCII quoting and non-ASCII response filenames, byte output, explicit extended
  values, and no accidental adoption of download rules by multipart readers.
- Repeated Vary fields, wildcard, casing, mutation return value and unrelated
  repeated-field preservation.
- Comma-containing and empty tags, exact weakness syntax, strong/weak matching,
  repeated conditional fields and wildcard representation-existence cases.
- End-to-end 304 versus normal file delivery, HEAD, malformed condition handling,
  conditional/date precedence and preservation of existing range behavior.
- Existing WWW-Authenticate formatter calls/overrides and Auth example responses.

Use grammar round trips only within the supported grammar; do not insist that
formatting preserves original whitespace/quoting. Reuse existing example tests
and add targeted regressions rather than repeating all parser cases per example.
Run the applicable suites and normal repository gate at implementation time;
report independently established pre-existing failures separately.

## Out of scope and completion

No server/spec repository changes, OAuth flows, auth policy engine, cookie work,
new Range support, complete caching/precondition framework, generic structured
fields parser, or new content-negotiation API. Existing Request::Negotiate can be
audited for reuse, but negotiation policy changes require separate scope review.

Done means the APIs, selected consumer migrations, reference docs and focused
examples agree; the approved runtime behaviors are verified; and the existing
raw primitives still provide the escape route. The next artifact after review
is an implementation plan, not runtime code in this design-writing step.
