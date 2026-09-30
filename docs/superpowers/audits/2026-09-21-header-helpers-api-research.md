# Header helpers: API research and migration map

Date: 2026-09-21. Checkout examined: `feature/universal-connection-tools`,
`1c22588`.

Status: discussion draft, not an approved implementation specification. Names
and contracts below are recommendations for review. No runtime code changed.

The subsequent discussion approved the choices recorded below, including file
If-None-Match migration. The consolidated implementation-facing design is
[Header helpers design](../specs/2026-09-21-header-helpers-design.md).

## Goal and agreed scope

Make ordinary header work short and understandable while keeping raw header
operations available. Retain `PAGI::Headers` and its ordered pairs, casing,
duplicate access, and opaque raw values. Investigate four families: authentication
fields, parameterized fields, token lists, and entity tags. Dates are a possible
small follow-up, using the existing dependency.

The immediate example is repeated Authorization parsing in Auth backends. This
work should also remove repeated parsing elsewhere. Authentication middleware
continues to pass Request to the application's backend. Header helpers do not
authenticate users, select failures, or send responses.

Approved after comparing library behavior: use `raise_on_error => 1` for explicit
failure reporting. Both modes use the same parsing rules; the option changes
malformed input from undef to an exception. It does not make credentials required.

## What the comparisons establish

| Source examined | Useful precedent | Limit for this work |
| --- | --- | --- |
| [HTTP::Headers](https://metacpan.org/pod/HTTP::Headers) | Named Basic, media type, charset and date conveniences | Scalar duplicate reads and container normalization differ from PAGI |
| [HTTP::Headers::Util](https://metacpan.org/pod/HTTP::Headers::Util), source 7.04 | Independent parsers/formatters; ordered key/value arrays | Permissive token grammar; no strict complete-input validation contract |
| [HTTP::Headers::Auth](https://metacpan.org/dist/HTTP-Message/source/lib/HTTP/Headers/Auth.pm), source 7.04 | Challenge parsing and formatting | Extends/replaces methods in HTTP::Headers; does not solve Bearer extraction |
| [HTTP::Headers::ETag](https://metacpan.org/dist/HTTP-Message/source/lib/HTTP/Headers/ETag.pm), source 7.04 | Specialized entity-tag field handling | Tolerant normalization is not a substitute for current field grammar |
| [Mojo::Headers](https://docs.mojolicious.org/Mojo/Headers), [Mojo::Util](https://docs.mojolicious.org/Mojo/Util#header_params) | Named accessors plus independent value utilities | Many accessors return strings; parameter parsing is not field validation |
| [Werkzeug HTTP utilities](https://werkzeug.palletsprojects.com/en/stable/http/) | Value functions also exposed through request/response conveniences | Includes richer objects and recovery policies we need not adopt |

Context7 was consulted for the Perl libraries and Werkzeug. Where its coverage
was incomplete, primary documentation and source were read directly. HTTP-Message
source was pinned to 7.04; Mojo and Werkzeug source URLs below track their main
branches, so they establish inspected behavior rather than a pinned release claim.

Werkzeug is particularly useful as an architectural comparison. Its utilities
are usable independently, while request/response APIs expose convenient views.
Its parameter parser skips invalid portions. Its Authorization parser returns
`None` for some invalid Basic credentials, but its token handling is permissive.
These are precedents for ergonomic failure handling, not algorithms to copy
unchanged. [Authorization source](https://raw.githubusercontent.com/pallets/werkzeug/main/src/werkzeug/datastructures/auth.py)

Mojo's `header_params` returns a parameter hash and unconsumed remainder. That
separation is useful for composition. Its inspected implementation keeps the first
value for a repeated exact parameter name. We should make PAGI's duplicate
handling explicit rather than inherit it accidentally.
[Mojo source](https://raw.githubusercontent.com/mojolicious/mojo/main/lib/Mojo/Util.pm)

## Placement recommendation

1. `PAGI::Utils::Headers`: ordinary exported functions operating on header values.
2. `PAGI::Headers`: field-aware conveniences that handle multiplicity and delegate
   to the value functions.
3. `PAGI::Request`: existing shortcuts delegate to the same implementation.

Value functions do not accept Request, scope, and response duck types. Headers
methods handle the container; value functions handle values. Parsed results use
ordinary Perl scalars, arrays and hashes. No live parsed views, hidden write-back,
or new hierarchy of header objects is needed for these use cases.

Read helpers do not rewrite stored fields. Writers return `$headers`, consistent
with existing `set` and `add`. Raw operations retain their current behavior.

## Candidate public inventory

These are working names. The table identifies useful capabilities, not an
instruction to add every symmetrical getter and setter.

### Authentication and single-value fields

Approved naming and delegation: Request keeps `bearer_token` and `basic_auth`;
Headers exposes `authorization_bearer` and `authorization_basic`; standalone
`parse_authorization_bearer` and `parse_authorization_basic` functions live in
`PAGI::Utils::Headers`. Headers handles multiplicity and calls the value parser;
Request delegates to Headers.

Approved Basic return shape: all three entry points return the two-value list
`($username, $password)` as decoded bytes. Missing, another scheme, and malformed
input return `(undef, undef)` by default. With `raise_on_error => 1`, malformed
input throws; absence and another scheme still return `(undef, undef)`. Callers
check `defined $username`, allowing an empty username. Split at the first colon
so additional colons remain part of the password. Bearer returns a token scalar
or undef.

| Proposed API | Shape/purpose |
| --- | --- |
| `$headers->get_single($name, %opts)` | Raw scalar or undef; multiple occurrences are unusable, optionally an error |
| `parse_authorization_bearer($value, %opts)` | Token scalar or undef |
| `parse_authorization_basic($value, %opts)` | Two-value list `(username, password)` or `(undef, undef)` |
| `$headers->authorization_bearer(%opts)` | Checks all Authorization occurrences, then parses |
| `$headers->authorization_basic(%opts)` | Same multiplicity handling, decoded Basic two-value list |
| `$request->bearer_token(%opts)` | Existing convenience, delegates |
| `$request->basic_auth(%opts)` | Existing list-returning convenience, delegates |
| `www_authenticate($scheme, @params)` | Existing ordered-parameter formatter, canonical implementation in Utils |

`get_single` is opt-in: it does not change `get` or build a registry of singleton
fields. It makes other singleton use cases straightforward. Utility parsers
accept one scalar value; callers using them directly own field selection.

Prefer keeping `PAGI::Auth::www_authenticate` as a small delegating convenience,
including its current class/instance forms. Removing it is also possible, but
would add migration work without helping the four target examples. Its current
all-quoted parameter contract is documented, including Digest's need for raw
construction for some parameters. Moving it does not silently promise full
scheme-specific challenge serialization or a challenge parser.

Do not add generators, a universal credentials object, or a backend parser.
Unknown schemes remain accessible through raw fields. Proxy fields can use the
same value functions with `get_single('Proxy-Authorization')`; dedicated proxy
methods can wait for a consumer.

### Parameterized values

Approved shape: named Headers accessors expose the leading value and a parameter
hash through separate methods. `content_type` returns the normalized media type;
`content_type_parameters` returns its parameter hash. The corresponding
Content-Disposition methods expose the disposition and its parameters. A valid
field without parameters yields an empty parameter hash; absent or malformed
input yields undef, with `raise_on_error => 1` reporting malformed input.

The standalone `parse_header_parameters` returns a hash with `value` and an
ordered flat `parameters` array. This preserves repeated parameters for
field-specific checking. `format_header_parameters($leading_value, @params)`
takes flat parameter pairs and handles quoting and escaping. The response
filename-encoding convenience below is also approved.

| Proposed API | Shape/purpose |
| --- | --- |
| `parse_header_parameters($value, %opts)` | `{ value => $leading_value, parameters => [name, value, ...] }` or undef |
| `format_header_parameters($leading_value, @params)` | Semicolon-separated parameters with correct quoting |
| `quote_header_value($value)` | A quoted-string for callers constructing their own field grammar |
| `$headers->content_type(%opts)` | Bare normalized media type, or undef |
| `$headers->content_type_parameters(%opts)` | Parameter hash for normal field use, or undef |
| `$headers->content_disposition(%opts)` | Disposition token, or undef |
| `$headers->content_disposition_parameters(%opts)` | Parameter hash, or undef |
| `content_disposition($type, @params)` | Response-oriented formatter; a home for filename encoding |

The generic parser preserves parameter order and repeated names in a flat list;
ordinary field-specific conveniences expose hashes after checking duplicates.
Parameter names can be ASCII-folded, while values retain case and bytes. The
generic leading value remains uninterpreted; field-specific wrappers validate
and normalize it. The formatter is explicitly for semicolon-parameter syntax,
not a formatter for all HTTP fields. Auth challenges use a different separator.

Approved response filename behavior: `content_disposition('attachment',
filename => $filename)` uses a quoted `filename` parameter for ASCII names.
For a non-ASCII character string it emits UTF-8 percent-encoded `filename*`,
without inventing an ASCII transliteration or fallback. For example,
`résumé.pdf` becomes `filename*=UTF-8''r%C3%A9sum%C3%A9.pdf`.
Existing `file_response($path, filename => $filename)` delegates to this formatter.
This is a response-header convenience, not a multipart upload encoding policy.

Download filename encoding and multipart upload interpretation must remain
distinct. Response `filename*` can carry an internationalized filename and take
precedence over a fallback `filename`; multipart/form-data prohibits that
mechanism. Sharing lexical parsing is appropriate; automatically applying
response filename rules to uploads is not.
[RFC 6266 §4.3](https://www.rfc-editor.org/rfc/rfc6266.html#section-4.3),
[RFC 7578 §4.2](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.2),
[RFC 8187](https://www.rfc-editor.org/rfc/rfc8187.html)

Approved first scope: ordinary parameter parsing and quoting plus UTF-8 response
filenames through the response-oriented formatter. Preserve
unknown parameters. No automatic filesystem filename sanitization belongs here.

### Token lists and Vary

Approved APIs: `tokens` reads all occurrences of the named token-list field and
preserves token spelling and order. `has_token` uses exact comparison by default;
`case_insensitive => 1` requests insensitive membership. `add_vary` merges all
existing Vary fields, deduplicates names case-insensitively while retaining first
spelling, normalizes a wildcard-containing result to `*`, and returns `$headers`.
Its pure counterpart is `merge_vary($values, @field_names)`, where `$values` is
an arrayref of existing field values. These operations do not reinterpret
arbitrary fields or combine Set-Cookie values.

| Proposed API | Shape/purpose |
| --- | --- |
| `parse_header_tokens($value, %opts)` | Arrayref of tokens; preserves spelling/order |
| `$headers->tokens($name, %opts)` | Combines occurrences of a field the caller identifies as a token list |
| `$headers->has_token($name, $token, %opts)` | Exact membership by default; `case_insensitive => 1` is available |
| `merge_vary($values, @field_names)` | Pure function taking an arrayref of current Vary field values and returning one merged string |
| `$headers->add_vary(@field_names)` | Mutating convenience delegating to merge_vary |

Do not equate token syntax with case-insensitive comparison everywhere: HTTP
method names are case-sensitive, whereas Vary contains case-insensitive field
names. Default generic membership to exact comparison, with an explicit option
for insensitive comparison. Keep Vary's behavior in its named helper.
[RFC 9110 §9.1](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.1)

Vary merging preserves first spelling, removes repeated field names, and
collapses a wildcard-containing result to `*`. This collapse is a normalization
choice: current RFC grammar permits `*` among list members. Existing Pages output
`*, Accept` is redundant, not itself a demonstrated RFC violation.
[RFC 9110 §12.5.5](https://www.rfc-editor.org/rfc/rfc9110.html#section-12.5.5)

No generic comma-merging for Set-Cookie or arbitrary headers. Generic token-list
methods document their supported grammar; they do not guess it from every field
name. GZip and CORS adding separate Vary occurrences is valid; their migration is
for shared composition and deduplication, not to repair an inherently invalid form.

### Entity tags

Approved shapes: a parsed tag is `{ value => $opaque_bytes, weak => 0|1 }`.
A parsed conditional list is `{ any => 0, tags => [...] }`, while wildcard
input produces `{ any => 1, tags => [] }`. Missing or malformed input returns
undef; `raise_on_error => 1` reports malformed input. `etag_matches` defaults to
strong comparison, with `weak => 1` explicitly selecting weak comparison.
`format_etag` likewise defaults to a strong tag and accepts `weak => 1`.
These are ordinary data structures; response decisions remain with callers.

| Proposed API | Shape/purpose |
| --- | --- |
| `parse_etag($value, %opts)` | `{ value => $opaque_bytes, weak => 0|1 }` or undef |
| `format_etag($opaque_bytes, weak => 0|1)` | Valid entity-tag string |
| `parse_etag_list($values, %opts)` | Arrayref of field values in; `{ any => 0|1, tags => [...] }` or undef out |
| `etag_matches($parsed_list, $etag, weak => 0|1)` | Match a validated current tag; default strong comparison |
| `$headers->etag(%opts)` | Parses one ETag field |
| `$headers->if_none_match(%opts)` / `if_match(%opts)` | Parses all occurrences, returning the same list structure |

Keep wildcard state explicit. `etag_matches` is useful when a valid current ETag
exists; it must not pretend to decide wildcard preconditions for representations
that exist but have no ETag. That remains the caller's decision.

Commas can occur inside an opaque tag. Entity tags do not use ordinary
quoted-string unescaping. Weak comparison ignores tag strength; strong comparison
does not. If-None-Match uses weak comparison. Response status and precondition
ordering remain outside these utilities.
[RFC 9110 §8.8.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.8.3),
[§13.1.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.2)

### Deferred candidates

Dates can continue using the already-declared `HTTP::Date`. Its existing
`str2time` and `time2str` cover parsing/formatting; add wrappers only if consumers
benefit. No broad date-accessor family is needed to complete the four examples.
[HTTP::Date](https://metacpan.org/pod/HTTP::Date)

Defer Link, Cache-Control objects, Retry-After, cookies, Range expansion, a new
Accept negotiation API, automatic scheme dispatch, and HTTP wire parsing.
`Request::Negotiate` is a consumer to audit for quoted separators, not a reason
to redesign negotiation policy in this project.

## Approved error-reporting contract

Use the same syntax recognition in both modes. The default reports unusable
input with undef (the pair `(undef, undef)` for Basic);
`raise_on_error => 1` raises a descriptive exception instead.
The descriptive name avoids suggesting that validation is disabled by default.
This contract is approved; the remaining candidate APIs still need review.

FastAPI's HTTPBearer provides a related error-reporting switch, `auto_error`,
but also treats missing credentials as an HTTP error when enabled. PAGI's option
reports malformed input only and does not select an HTTP response. Starlette's
documented backend likewise distinguishes absence/another scheme from decoding
errors, with the distinction implemented by application code.
[FastAPI source](https://github.com/fastapi/fastapi/blob/master/fastapi/security/http.py),
[Starlette authentication example](https://starlette.dev/authentication/)

For Bearer extraction:

| Input | Default | raise_on_error => 1 |
| --- | --- | --- |
| No Authorization field | undef | undef |
| One field with another identifiable scheme | undef | undef |
| One valid Bearer field | token | token |
| Empty/malformed Bearer credentials | undef | exception |
| Multiple Authorization fields, even identical | undef | exception |

Strip surrounding HTTP optional whitespace, not arbitrary Perl whitespace.
Validate Bearer credential syntax without decoding the token or deciding whether
it is a JWT. A failed lookup or signature check is still backend work.
[RFC 6750 §2.1](https://www.rfc-editor.org/rfc/rfc6750.html#section-2.1)

Basic decoding should validate the encoding and required separator, split at the
first colon, reject forbidden control characters, and return credential bytes.
Do not silently pick a character encoding or copy the example's ASCII-only
application restriction into the general helper.
[RFC 7617 §2](https://www.rfc-editor.org/rfc/rfc7617.html#section-2)

Formatter misuse and invalid API arguments are programming errors and raise
regardless of the option. No global last-error variable or error-object hierarchy
is proposed. Parsing exceptions do not cause automatic HTTP responses;
applications that request exceptions catch them where they choose a response.

For the remaining parsers, the spec must state absent, empty, and malformed
results separately where their grammars differ. Do not mechanically assume
every empty field is an error or that partial recovery is always appropriate.

## Four application checks (proposed APIs, not runnable today)

### 1. Authentication

Approved migration: the primary Bearer examples use `raise_on_error => 1` and
follow the standards-based response distinctions below. The reason is the
protocol contract, not preserving existing implementation behavior.

| Situation at a protected Bearer endpoint | Response |
| --- | --- |
| No credentials or an unsupported scheme | 401 with a Bearer challenge, without an error parameter |
| Malformed credential presentation | 400 with `error="invalid_request"` |
| A presented token rejected by token parsing/verification | 401 with `error="invalid_token"` |
| Valid token lacking required privileges | 403 with `error="insufficient_scope"` |

The Bearer status mappings are SHOULD-level recommendations. Every 401 requires
a WWW-Authenticate challenge. A well-formed Bearer field containing an invalid
JWT belongs to the token-failure case, not the presentation-error case. The
middleware and header helpers still do not choose responses.
[RFC 6750 §3.1](https://www.rfc-editor.org/rfc/rfc6750.html#section-3.1),
[RFC 9110 §15.5.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.5.2)

The documentation may also show the simpler extraction form for applications
that intentionally treat unusable credentials as absent:

```perl
my $token = $request->bearer_token;
return unauth_result() unless defined $token;

# Existing verification and auth_result construction follow unchanged.
```

That form gives missing and malformed credentials the same guest result. It is
not the primary example of the response distinctions above. The primary examples
replace manual multiplicity checks and regular expressions with:

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
```

The exception-handling example removes all header mechanics but retains the
application's choice of failure. Use `defined`, since a token of `0` is a value.

### 2. Download filename and upload metadata

Current file responses manually escape quotes and backslashes. Proposed use:

```perl
$response->headers->set('Content-Disposition',
    content_disposition('attachment', filename => 'quarterly; "final".csv'));
```

Both multipart readers use the shared parameter parser, then extract `name` and
`filename` under multipart rules. Request's two boundary extraction sites use
Content-Type parameters rather than their own regexes. No new body parser needed.

### 3. Middleware composition

```perl
$response->headers->add_vary('Accept');
$response->headers->add_vary('Origin', 'Accept-Encoding');
# One composed Vary value; existing unrelated fields retained.
```

Pages works with flat header lists internally; it can call the pure function
using its existing field extraction/replacement helpers. Do not force a container
conversion or change its flat public header convention just to share an algorithm.

### 4. Conditional GET

```perl
my $condition = $request->headers->if_none_match;
if ($condition && etag_matches($condition, $current_etag, weak => 1)) {
    # Existing response policy chooses 304 for the applicable GET/HEAD case.
}
```

This illustrates matching, not a complete precondition evaluator. The ETag is a
valid current representation tag; status eligibility and other conditions belong
to the caller.

## Migration map

Paths below are relative to PAGI-Tools.

| Existing area | Required review/update |
| --- | --- |
| `lib/PAGI/Headers.pm`, `t/headers.t` | Add documented conveniences; retain existing raw-container tests |
| New `lib/PAGI/Utils/Headers.pm` | Single shared implementations, optional exports, exact function reference |
| `lib/PAGI/Request.pm`, `t/request/05-auth.t` | Delegate auth helpers; replace Content-Type and both multipart boundary parsing sites; document stricter recognition |
| `lib/PAGI/Request/{MultiPartHandler,MultipartStream}.pm` | Replace duplicated disposition regexes; regression coverage in buffered and streaming tests |
| `lib/PAGI/Response/File.pm`, `t/response/04-file.t` | Shared disposition formatting; review explicit filename encoding contract |
| `lib/PAGI/Pages.pm`, `t/pages/02-rendering-negotiation.t` | Shared pure Vary merge while retaining flat-list interface |
| `lib/PAGI/Middleware/{CORS,GZip}.pm` | Shared Vary merge; retain other response fields |
| `lib/PAGI/Headers.pm::dehop` | Consider sharing token parsing while retaining Connection-nominated removal |
| `lib/PAGI/Middleware/ConditionalGet.pm`, `t/middleware/conditional-get.t` | Shared ETag parsing, all list occurrences, explicit weak comparison |
| `lib/PAGI/Response/File/Plan.pm` | Shared ETag validation and approved GET/HEAD list/weak/wildcard matching |
| `lib/PAGI/Middleware/ETag.pm` | Use common tag formatting if it removes duplicated syntax; retain generation policy |
| `lib/PAGI/Request/Negotiate.pm`, `t/request-negotiate.t` | Audit quoted delimiter handling; separate any actual policy expansion |
| `lib/PAGI/Auth.pm`, `t/auth/07-www-authenticate.t` | Delegate formatter if relocation is approved; keep documented escape hatch and invocation forms |
| `examples/auth-jwt-sandbox/{app.pl,app2.pl,README.md}` | Remove manual parsing; explicitly choose simple or exception-handling flow |
| `examples/auth-notes/{app.pl,README.md}` | Same; preserve intended response/failure behavior |
| `examples/auth-extensions/{02-basic-backend.pl,06-header-primitives.pl,README.md}` | Demonstrate shared Basic parsing and independent header primitives |
| Auth/Request/Headers POD, `lib/PAGI/Tools/{Cookbook,Tutorial}.pod`, Response POD | Exact signatures, outcomes, class/instance behavior where already offered, and raw alternatives |
| `t/auth/{11-extension-examples,12-cookbook}.t`, Auth integration tests | Update relevant public examples and behavior assertions, without multiplying tests for identical variants |

Other formatter imports in `examples/auth-extensions` and protocol examples need
changing only if the Auth convenience is removed. Preserve historical design and
handoff documents as history; link superseding contracts instead of bulk rewriting
them. Review `Changes` and declared dependencies when implementation is planned.

File planning currently documents exact comparison against the first
If-None-Match field. The user approved replacing this with shared list/weak
matching for GET/HEAD file responses, including repeated fields, wildcard for an
existing representation, and comma-containing tags. This is a deliberate behavior
change with corresponding docs/tests, not a mechanical cleanup.
ConditionalGet also has precondition-ordering
logic outside parsing that should be reviewed in the eventual integration task.
Do not conceal a full conditional-request redesign inside a utility refactor.

## Evidence and verification needed

Read-only probes confirmed two existing problems:

- `ConditionalGet->_etag_matches('"a,b"', '"a,b"')` returns false.
- The buffered disposition parser truncates `filename="a\"b.txt"` to `a\`;
  the streaming parser contains the same regex implementation.

A Vary probe returns `*, Accept` after merging Accept into `*`. That is a
normalization opportunity, not recorded here as an RFC violation.

Meaningful implementation tests should cover:

- Absence, another auth scheme, duplicate fields, malformed encoding, the token
  `0`, and the return-undef/raise distinction; no token verification inside helpers.
- Quoted semicolons/commas, escaped quotes, mixed-case parameter names, duplicates,
  empty parameter values, and complete-input handling.
- Buffered/streaming parity on the same upload metadata; quoted multipart boundary.
- Multiple Vary occurrences, casing, wildcard, and unrelated repeated fields.
- Comma-containing tags, weak/strong comparison, list occurrences, wildcard, and
  malformed conditions; one integration check in each migrated consumer.
- Formatter/parser round trips within each explicitly supported grammar, rather
  than tests that just reproduce the implementation's expressions.

No full application suite was run for this research; no runtime files changed.

## Dependency recommendation

Keep existing MIME::Base64/HTTP::Date facilities. Do not add Mojolicious solely
for a small parsing utility. HTTP::Headers::Util is a plausible dependency if we
choose its recovery contract, but it does not provide complete strict recognition.
Wrapping it with a second parser to recover that property would duplicate work.

For the approved same-parser/error-reporting contract, prefer a small shared
scanner for the specifically supported parameter/list syntax, plus direct
field-specific Basic/Bearer and ETag parsing. Reuse library algorithms only with
appropriate license attribution. This recommendation is based on the inspected
source, not a benchmark or a claim that all independent code is preferable.
[HTTP::Headers::Util 7.04 source](https://fastapi.metacpan.org/v1/source/OALDERS/HTTP-Message-7.04/lib/HTTP/Headers/Util.pm)

## Approved outcome

Auth names, Basic's list return shape, parameter APIs and return shapes, UTF-8
response filenames, token-list/Vary APIs, and ETag structures/comparison are
approved. The error-reporting option is `raise_on_error => 1`.

Primary Auth examples will use exceptions to distinguish malformed presentation
from token verification failures and follow the agreed Bearer response mappings.
The Request shortcuts will adopt the approved shared parsing rules.

File If-None-Match migration is approved. Consolidate these decisions in the
linked design spec; further ecosystem research is not required before planning.
