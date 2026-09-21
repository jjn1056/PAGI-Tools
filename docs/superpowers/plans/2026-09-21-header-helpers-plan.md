# Header Helpers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add small public header utilities, delegate Headers/Request conveniences to them, and replace the selected duplicate parsers across code, documentation, and examples.

**Architecture:** `PAGI::Utils::Headers` parses and formats values synchronously; `PAGI::Headers` selects fields and handles multiplicity; Request delegates. Consumers retain authentication decisions, response status, representation existence, and conditional-response policy. Implement this as one coordinated plan because the consumer changes depend on the same utility contract, with independently reviewable tasks for each family.

**Tech Stack:** Perl (existing distribution floor 5.018), Exporter, Carp, existing MIME::Base64, core Encode, existing HTTP::Date, Test2::V0, Future-based in-process test harnesses. Use the installed Perl 5.40 environment for this checkout's tests; do not raise the library version floor.

**Spec:** [Header helpers and consumer migration](../specs/2026-09-21-header-helpers-design.md), reviewed section by section with the user. Read the spec as well as this plan. Research: [API research](../audits/2026-09-21-header-helpers-api-research.md).

## Global Constraints

- “Work remains on the current working branch.”
- “`get` remains last-value lookup.”
- “Headers read methods do not rewrite fields.”
- “Mutating conveniences return the Headers instance, consistent with `set` and `add`.”
- “Missing input is not an error in either mode.”
- “Unknown options, wrong argument shapes, and invalid formatter arguments are programming errors regardless of this option.”
- “Exceptions identify the operation and problem without echoing credentials.”
- “The Basic APIs are documented and demonstrated in list context.”
- “No parsed-value cache or mutation-observer machinery is needed.”
- “Use existing Base64 facilities, core Encode for UTF-8 filename encoding, and the already-declared HTTP::Date where dates are needed.”
- “No server/spec repository changes, OAuth flows, auth policy engine, cookie work, new Range support, complete caching/precondition framework, generic structured fields parser, or new content-negotiation API.”

Use `raise_on_error`, not a `strict` option or alternate grammar. The spec owns the return shapes and absence/empty distinctions. Raw header byte handling, flat response header lists, nested scope pairs, and repeated Set-Cookie fields stay intact. Functions are optional exports, not factories or app adaptors. No new value classes or general parsing framework.

## Execution status

All eight tasks are implemented and individually reviewed. Full-gate results and execution decisions are recorded in the [handoff](2026-09-21-header-helpers-handoff.md); whole-change review is complete, with its minor documentation finding corrected and re-reviewed. A checked step means it was performed, not that pre-existing environment failures disappeared.

## Work map and execution boundary

| Item | Value |
| --- | --- |
| Repository | `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` |
| Ticket | Header helpers and consumer migration; no external issue number supplied |
| Branch | `feature/universal-connection-tools` |
| Recorded base | `3f12918dd783efc18f8f43acf9cde4d9fa4792c5` (reviewed design and research) |
| Owned changes | Files listed in the task inventory below; related focused tests/POD only |
| Deployment boundary | Local library/example changes and commits; no deployment, server change, merge, or publication |
| Push target | If separately authorized: `origin/feature/universal-connection-tools`, repository `https://github.com/jjn1056/PAGI-Tools.git`; no push in this plan |

At planning time, `docs/superpowers/plans/2026-09-08-universal-connection-tracking.md` was modified and unrelated `.pagi-*`/`.superpowers/` files were untracked. Preserve them. Before execution, record actual HEAD/status and reconcile intervening changes rather than resetting to this base. Use targeted staging, never `git add .`. Working docs are ignored; force-add only an explicitly selected planning document if committing it.

Tasks are sequential because several extend `Utils::Headers`, `Headers`, and Request. With subagents, give each task one owner and review before the next; do not let concurrent writers edit these shared modules. Do not add a worktree: the user explicitly selected this branch.

## File responsibilities

| Files | Responsibility |
| --- | --- |
| New `lib/PAGI/Utils/Headers.pm` | Optional pure value functions, focused private lexical helpers, complete function POD |
| `lib/PAGI/Headers.pm` | Singleton and named field reads, token membership, Vary mutation, exact method POD |
| `lib/PAGI/Request.pm` | Delegating shortcuts and both multipart boundary entry points |
| `lib/PAGI/Auth.pm` | Existing formatter invocation/override surface delegating to Utils |
| `lib/PAGI/Request/{MultiPartHandler,MultipartStream}.pm` | Shared disposition parsing without changing upload ownership/streaming |
| `lib/PAGI/Response/File.pm`, `File/Plan.pm` | Filename formatting and conditional selected-file planning |
| `lib/PAGI/Middleware/{ConditionalGet,ETag}.pm` | Conditional response policy and shared ETag serialization |
| `lib/PAGI/Pages.pm`, `Middleware/{CORS,GZip}.pm` | Common Vary composition, existing array conventions preserved |
| New `t/utils/headers-{auth,parameters,tokens,etag}.t` | Grammar/error tests once per utility family |
| Existing consumer tests listed below | Delegation, actual observable responses, streaming and range regressions |
| Auth examples, module POD, Cookbook, Tutorial, `Changes` | Complete API and migration guidance, with ordinary raw-header escape routes |

Private helpers inside Utils should earn their existence through actual reuse (ASCII folding, argument validation, quoted strings). Do not expose internal utilities publicly or create a `PAGI::Common` parser subsystem. Keep `dehop` and Request::Negotiate behavior unchanged; inspect them during the final audit, but do not force them onto a grammar that loses information.

## Task 1: Singletons, Basic/Bearer parsing, and challenge formatting

**Files:** Create `lib/PAGI/Utils/Headers.pm`, `t/utils/headers-auth.t`. Modify `lib/PAGI/Headers.pm`, `lib/PAGI/Request.pm`, `lib/PAGI/Auth.pm`, `t/headers.t`, `t/request/05-auth.t`, `t/auth/07-www-authenticate.t`.

**Interfaces:** Produce `parse_authorization_bearer($value, %opts) -> token|undef`, `parse_authorization_basic($value, %opts) -> (username,password)|(undef,undef)`, `www_authenticate($scheme,@pairs) -> string`. Produce Headers `get_single($name,%opts)`, `authorization_bearer(%opts)`, `authorization_basic(%opts)`; Request forwards `%opts` through its existing shortcuts. `%opts` permits only `raise_on_error` for these reads.

- [x] Record the work map's actual execution HEAD and establish the baseline with `perlbrew exec --with perl-5.40.0@default prove -lr t`. Record skipped optional dependencies and independently establish any pre-existing failure before modifying code. Do not run server checkouts or a browser.
- [x] Add focused assertions using the existing Test2 style. Representative new tests:

```perl
use strict;
use warnings;
use Test2::V0;
use PAGI::Utils::Headers qw(parse_authorization_bearer parse_authorization_basic www_authenticate);
use PAGI::Headers;

is(parse_authorization_bearer('bEaReR 0'), '0', 'zero is a token');
is(parse_authorization_bearer('Basic Og==', raise_on_error => 1), undef,
    'another scheme is not a malformed Bearer credential');
is(parse_authorization_bearer('Bearer one two'), undef, 'no partial credential');
like(dies { parse_authorization_bearer('Bearer secret extra', raise_on_error => 1) },
    qr/Bearer|bearer|authorization/i, 'malformed credential can throw');
is([parse_authorization_basic('Basic Og==')], ['', ''], 'empty components are values');
is([parse_authorization_basic('Basic dTpwOnE=')], ['u', 'p:q'], 'first colon splits');
is([parse_authorization_basic('Basic !!!!')], [undef, undef], 'invalid Base64');
my $headers = PAGI::Headers->new([
    ['Authorization', 'Bearer first'], ['authorization', 'Bearer second'],
]);
is($headers->get('Authorization'), 'Bearer second', 'raw get still returns last');
is($headers->authorization_bearer, undef, 'duplicate credentials not selected');
ok(dies { $headers->get_single('Authorization', raise_on_error => 1) },
    'singleton duplicate throws when requested');
is(www_authenticate('Bearer', realm => 'api'), 'Bearer realm="api"', 'plain value');
done_testing;
```

Also cover absent/empty values; SP versus tab credential separators; token alphabet/padding; supported scheme without credentials; invalid scheme syntax; other identifiable schemes; Base64 padding/alphabet/trailing garbage; decoded missing colon and controls; raw byte credentials; unknown options and references. Assert errors do not contain the presented secret. Use one table for recognition in both reporting modes rather than duplicating all cases in Request tests. Add a small Request delegation/duplicate case.

- [x] Run the focused command below and verify the new API assertions fail for the intended missing behavior.
- [x] Implement optional exports and the parsing functions. Use anchored ASCII grammar and SP/HTAB only for surrounding OWS. Recognize a scheme before parsing supported credentials; an identifiable different scheme returns no credentials. Bearer uses RFC 6750's token alphabet and one or more SP between scheme/token. For Basic, validate conventional Base64 groups/padding before `decode_base64`, then require a colon and reject decoded CTLs. Do not silently repair credentials or perform character decoding.
- [x] Implement multiplicity checks before auth parsing and delegate Request shortcuts. These illustrate the public call boundaries (argument validation still applies even on missing input):

```perl
# In PAGI::Request, replacing the old regex/decoder bodies:
sub bearer_token {
    my ($self, @opts) = @_;
    return $self->headers->authorization_bearer(@opts);
}
sub basic_auth {
    my ($self, @opts) = @_;
    return $self->headers->authorization_basic(@opts);
}

# In PAGI::Auth: preserve existing invocant recognition/validation.
sub www_authenticate {
    my ($proto, @args) = _factory_invocation(@_);
    _validate_invocant($proto);
    return PAGI::Utils::Headers::www_authenticate(@args);
}
```

Use `use PAGI::Utils::Headers ();` in Auth to avoid importing over its own public method. Move formatter validation/quoting to Utils, preserving all-quoted parameters, order, duplicate rejection, class/instance calls and override behavior. Do not introduce a circular dependency from Utils to Auth. Update error assertions only where implementation ownership changes their prefix, retaining checks for actual problems.
- [x] Document exact signatures, `(undef,undef)` and list context, no verification/encoding magic, the error option, duplicate-field behavior, and deliberately tighter Request recognition. Preserve Auth's public invocation documentation and Digest limitation.
- [x] Run `perlbrew exec --with perl-5.40.0@default prove -l t/utils/headers-auth.t t/headers.t t/request/05-auth.t t/auth/07-www-authenticate.t`. Expect all pass. Review the diff, stage only this task's changed files, and commit `feat: add shared authentication header helpers`.

## Task 2: Parameter parsing and named Content-Type/Disposition reads

**Files:** Modify Utils/Headers/Request. Create `t/utils/headers-parameters.t`. Extend `t/headers.t`, `t/request/01-basic.t` and relevant content-type assertions in `t/request/09-form.t`.

**Interfaces:** Produce `parse_header_parameters($value,%opts) -> {value,parameters=>\@pairs}|undef`, `format_header_parameters($leading,@pairs) -> bytes`, `quote_header_value($bytes) -> quoted bytes`. Headers produces `content_type`, `content_type_parameters`, `content_disposition`, `content_disposition_parameters`, each accepting `raise_on_error`. Request `content_type(%opts)` retains `''` on absent/unusable input.

- [x] Add grammar tests including this quoted-delimiter case:

```perl
is(parse_header_parameters('attachment; filename="quarterly; report.txt"'), {
    value => 'attachment', parameters => [filename => 'quarterly; report.txt'],
}, 'semicolon inside quoted parameter is data');
is(parse_header_parameters('x; A=one; a=""'), {
    value => 'x', parameters => [a => 'one', a => ''],
}, 'generic result retains duplicates and quoted empty values');
is(format_header_parameters('attachment', filename => 'quarterly; report.txt'),
    'attachment; filename="quarterly; report.txt"', 'formatter quotes when needed');
my $h = PAGI::Headers->new([['Content-Type', 'Text/HTML; charset=UTF-8']]);
is($h->content_type, 'text/html', 'named leading value normalized');
is($h->content_type_parameters, { charset => 'UTF-8' }, 'value case retained');
$h->set('Content-Type', 'text/plain; Charset=a; charset=b');
is($h->content_type_parameters, undef, 'named reader rejects duplicate parameters');
```

Cover escaped quote/backslash, HTAB/SP OWS, missing leading value, missing equals/value, unterminated quotes, trailing garbage, empty semicolon slots, controls/wide characters, unknown parameters, `{}` versus undef, duplicate fields, and detached parsed results. Generic leading values are not full arbitrary header fragments: formatting rejects comma/semicolon/control injection. Named methods separately require media-type `token/token` or a disposition token.
- [x] Run `perlbrew exec --with perl-5.40.0@default prove -l t/utils/headers-parameters.t t/headers.t t/request/01-basic.t t/request/09-form.t` and observe the new failures.
- [x] Implement a complete-input cursor scan, not `split /;/`. Consume the leading value, then each semicolon/name/equals/token-or-quoted-value; after a quoted value only OWS, another semicolon or end is valid. Fold parameter names with ASCII translation; store alternating names/values in an array. In named readers, detect duplicate names before building a hash, validate the leading grammar, and reject the whole value on any failure.
- [x] Share the quoted-string escape logic with `www_authenticate`, without changing its always-quoted output. Preserve raw value bytes; never percent-decode `filename*` in these reads. Use this Request delegation:

```perl
sub content_type {
    my ($self, @opts) = @_;
    return $self->headers->content_type(@opts) // '';
}
```

- [x] Add full POD with independent utility and named-reader examples, duplicate policy, no mutation, and raw `get` alternatives. Audit Request's `is_json`/form predicates for the now-normalized result.
- [x] Run the Task 2 command plus `t/utils/headers-auth.t t/auth/07-www-authenticate.t` with the same Perl/prove prefix. Expect pass. Commit only task files as `feat: add parameterized header helpers`.

## Task 3: Multipart consumers share parameter parsing

**Files:** Modify `lib/PAGI/Request.pm`, `lib/PAGI/Request/MultiPartHandler.pm`, `lib/PAGI/Request/MultipartStream.pm`; extend `t/request/11-multipart-handler.t`, `t/request/multipart-stream.t`, `t/request/multipart-stream-integration.t`, and `t/multipart-limits.t` as needed for the listed integration cases.

**Interfaces:** Consume named Content-Type parameters and the shared disposition reader. Keep existing part/upload return values, unknown metadata parameters, cleanup, limits and body ownership. An unusable disposition yields no parsed metadata, never a partially recovered filename; do not add response filename* decoding to uploads.

- [x] In existing buffered and streaming fixtures add `Content-Disposition: form-data; name="upload"; filename="a\"b.txt"` and assert the filename is `a"b.txt`. Add a quoted semicolon in a name, `filename = "report.txt"`, an unknown parameter, and `filename*` alone (must not become `filename` or classify as a file). An invalid quoted tail must not yield partially extracted metadata.
- [x] Exercise both Request entry points with `Content-Type: multipart/form-data; boundary="test boundary"` and a matching body delimiter. Preserve existing missing-boundary failures; add duplicate/broken parameter cases. Verify a quoted empty filename is still a defined filename. Test that spaced `filename =` metadata uses the file size limit, not the form-field limit.
- [x] Run `perlbrew exec --with perl-5.40.0@default prove -l t/request/11-multipart-handler.t t/request/multipart-stream.t t/request/multipart-stream-integration.t t/multipart-limits.t`; observe the new failing cases.
- [x] Replace both boundary regexes with shared extraction:

```perl
my $parameters = $self->headers->content_type_parameters;
my $boundary = defined($parameters) ? $parameters->{boundary} : undef;
croak 'No boundary found in Content-Type'
    unless defined($boundary) && length($boundary);
```

Use the existing error mechanism of each entry point. Replace each disposition regex loop with a small adapter to the same named reader:

```perl
my $value = $headers->{'content-disposition'};
return {} unless defined $value;
my $fields = PAGI::Headers->new([['Content-Disposition', $value]]);
return $fields->content_disposition_parameters // {};
```

Do not introduce another grammar in the adapters. In MultiPartHandler's `on_header`, use the same parsed metadata for `defined $metadata->{filename}` instead of `/filename=/`; share that part-local metadata with finalization if convenient. Do not add persistent header caches. Leave the underlying HTTP::MultiPartParser and part-header storage contract alone.
- [x] Update upload/boundary documentation where parsing behavior changes. Run `perlbrew exec --with perl-5.40.0@default prove -lr t/request t/multipart-limits.t t/request-body-stream.t`; ensure cancellation, disconnection, cleanup, and limits remain green. Commit `refactor: share multipart header parameter parsing`.

## Task 4: Response filename formatting

**Files:** Modify Utils, `lib/PAGI/Response/File.pm`, `t/utils/headers-parameters.t`, `t/response/04-file.t`.

**Interfaces:** Produce `content_disposition($disposition,@pairs) -> byte string`; File's existing `filename`/`inline` options consume it. No new public File options.

- [x] Add these formatter assertions and a file-response wire-header assertion using existing `run_response`, `write_file`, and `event_header` helpers:

```perl
use utf8;
is(content_disposition('attachment', filename => 'report.pdf'),
    'attachment; filename="report.pdf"', 'ASCII download filename');
my $value = content_disposition('attachment', filename => 'résumé.pdf');
is($value, "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf", 'UTF-8 extended filename');
ok(!utf8::is_utf8($value), 'formatter produces a byte string');
is(content_disposition('attachment', filename => 'resume.pdf',
    'filename*' => "UTF-8''r%C3%A9sum%C3%A9.pdf"),
    "attachment; filename=\"resume.pdf\"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf",
    'explicit ASCII fallback and extended name');
```

Cover quote/backslash escaping, filename controls, invalid disposition/parameter names, duplicate names, malformed percent escapes in explicit extended values, and generated/explicit filename* collision. Keep tests distinguishing characters from already-encoded bytes; document the caller's decoding responsibility rather than guessing it.
- [x] Run `perlbrew exec --with perl-5.40.0@default prove -l t/utils/headers-parameters.t t/response/04-file.t` and observe expected failures.
- [x] Implement ASCII filename quoting and non-ASCII encoding via `Encode::encode('UTF-8', ...)` with invalid character input rejected. Percent-encode UTF-8 octets outside RFC 8187 attr-char; prefix `UTF-8''`. Validate explicit filename* as an ASCII extended-value (charset/language/value, complete percent escapes); preserve it unquoted and do not decode/re-encode it. Use shared quoting for other parameters, preserve ordered pairs and validate unique names. Downgrade supported byte output without losing data.
- [x] Replace File's manual backslash substitution and concatenation:

```perl
my @parameters = exists($self->{_filename})
    ? (filename => $self->{_filename}) : ();
my $disposition = PAGI::Utils::Headers::content_disposition(
    $self->{_inline} ? 'inline' : 'attachment', @parameters,
);
```

Keep existing constructor validation for filename controls, configured-header replacement and inline-without-filename behavior. Update File POD to explain character input and actual emitted fields.
- [x] Run the Task 4 command and `perlbrew exec --with perl-5.40.0@default prove -l t/app-file.t t/protocol-refusal-applications.t`. Commit `feat: format Unicode download filenames`.

## Task 5: Token lists and common Vary composition

**Files:** Modify Utils, Headers, `lib/PAGI/Pages.pm`, `lib/PAGI/Middleware/CORS.pm`, `lib/PAGI/Middleware/GZip.pm`. Create `t/utils/headers-tokens.t`; extend `t/headers.t`, `t/pages/02-rendering-negotiation.t`, `t/middleware/06-security.t`, `t/middleware/07-compression.t` in their existing CORS/GZip sections.

**Interfaces:** Produce `parse_header_tokens($value,%opts) -> arrayref|undef`, Headers `tokens($name,%opts)`, `has_token($name,$token,%opts)`, `add_vary(@names) -> self`, and `merge_vary(\@existing_values,@names) -> string`. Only `has_token` also accepts `case_insensitive`.

- [x] Add representative tests:

```perl
is(parse_header_tokens('GET,, HEAD, GET'), ['GET', 'HEAD', 'GET'], 'order/repeats retained');
is(parse_header_tokens(undef), [], 'absent token list');
is(parse_header_tokens('GET, "HEAD"'), undef, 'quoted members not token grammar');
is(merge_vary(['Origin', 'accept-encoding'], 'Accept-Encoding', 'Accept'),
    'Origin, accept-encoding, Accept', 'first spelling with case-insensitive deduplication');
is(merge_vary(['Origin, *'], 'Accept'), '*', 'wildcard normalization');
my $h = PAGI::Headers->new([['Vary','Origin'], ['Set-Cookie','a=1'], ['Set-Cookie','b=2']]);
is($h->add_vary('Accept'), $h, 'chainable writer');
is([$h->get_all('Set-Cookie')], ['a=1','b=2'], 'unrelated repeated fields retained');
```

Cover missing/empty list/no-op, multiple field occurrences, exact versus ASCII-insensitive membership, invalid options/tokens, malformed existing Vary throwing before mutation, and wildcard with other valid names. `Vary: *, Accept` is valid input that normalizes, not an RFC violation.
- [x] Run `perlbrew exec --with perl-5.40.0@default prove -l t/utils/headers-tokens.t t/headers.t` and observe failures.
- [x] Implement token parsing by splitting this specific grammar on commas, trimming only SP/HTAB and validating each nonempty token. Parse all fields before returning a Headers result. `merge_vary` validates all supplied names/values, preserves first spelling/order and then collapses wildcard; `add_vary` calls `set` only after successful composition.
- [x] Add actual Pages/CORS/GZip response assertions with an existing Vary field and repeated Set-Cookie fields, then replace local appending/merging. Pages keeps its flat-list helpers:

```perl
return _replace_header($headers, 'Vary', merge_vary(
    [_header_values($headers, 'Vary')], 'Accept',
));
```

Middleware uses nested-pair extraction/replacement or a local Headers object and `to_pairs`; don't accidentally turn flat lists into nested lists or change compression/CORS policy. Document shared Vary semantics and exact token method contracts. Leave `dehop` unchanged so malformed aggregate syntax doesn't erase usable Connection nominations.
- [x] Run `perlbrew exec --with perl-5.40.0@default prove -lr t/utils/headers-tokens.t t/headers.t t/pages t/middleware/06-security.t t/middleware/07-compression.t t/middleware/cors-warning.t t/35-gzip-concurrency.t`. Commit `feat: share token and Vary header handling`.

## Task 6: Entity-tag syntax and comparisons

**Files:** Modify Utils and Headers. Create `t/utils/headers-etag.t`; extend `t/headers.t`.

**Interfaces:** Produce `parse_etag($value,%opts) -> {value,weak}|undef`, `format_etag($opaque,weak=>$bool) -> bytes`, `parse_etag_list(\@values,%opts) -> {any,tags}|undef`, `etag_matches($condition,$current_wire_etag,weak=>$bool) -> boolean`. Headers `etag`, `if_none_match`, `if_match` accept `raise_on_error`. Comparison defaults strong, formatting defaults strong.

- [x] Add grammar and comparison tests:

```perl
is(parse_etag('W/"a,b"'), {value => 'a,b', weak => 1}, 'comma is opaque data');
my $condition = parse_etag_list(['"old"', 'W/"a,b"']);
is($condition, {any => 0, tags => [
    {value => 'old', weak => 0}, {value => 'a,b', weak => 1},
]}, 'all field occurrences parsed in order');
ok(!etag_matches($condition, '"a,b"'), 'strong comparison rejects weak candidate');
ok(etag_matches($condition, '"a,b"', weak => 1), 'weak comparison matches opaque value');
is(parse_etag_list([]), undef, 'absence');
is(parse_etag_list(['']), {any => 0, tags => []}, 'present empty list');
is(parse_etag_list(['*']), {any => 1, tags => []}, 'wildcard');
is(parse_etag_list(['*', '"a"']), undef, 'wildcard must stand alone');
is(parse_etag('w/"a"'), undef, 'weakness marker is exact uppercase W/');
```

Cover empty opaque tags, bytes/backslash preservation, invalid embedded quotes/controls, malformed complete lists, repeated tags, leading/trailing empty list members, duplicate ETag versus repeated conditional fields, formatter misuse, invalid current-tag arguments and both error modes. Match results must not mutate either operand.
- [x] Run `perlbrew exec --with perl-5.40.0@default prove -l t/utils/headers-etag.t t/headers.t`; observe missing behavior.
- [x] Implement a cursor scan for the conditional list, consuming each full entity-tag before inspecting commas. Reuse the entity-tag recognizer, not generic quoted-string unescaping. Combine input occurrences with list semantics after validating argument shapes. Wildcard is only a standalone condition. Validate the current wire ETag even when the condition is absent; missing/invalid current ETag is caller misuse, not representation nonexistence.
- [x] Implement comparison as explicit strength gating plus byte equality:

```perl
# After validating the parsed condition and parsing the current tag:
return 0 unless defined $condition;
return 1 if $condition->{any};
for my $candidate (@{$condition->{tags}}) {
    next if !$weak && ($candidate->{weak} || $current->{weak});
    return 1 if $candidate->{value} eq $current->{value};
}
return 0;
```

Here `$weak` is the validated `weak` option and `$current` is `parse_etag`'s successful result. Do not infer resource existence from an absent current tag. Document every return shape and a direct raw-value example.
- [x] Run Task 6 tests and all `t/utils/headers-*.t` using the same Perl/prove prefix. Commit `feat: add entity-tag parsing and comparison helpers`.

## Task 7: Conditional response and File integration

**Files:** Modify `lib/PAGI/Middleware/ConditionalGet.pm`, `lib/PAGI/Middleware/ETag.pm`, `lib/PAGI/Response/File/Plan.pm`, `lib/PAGI/Response/File.pm`; review `lib/PAGI/App/File.pm` call flow. Extend `t/middleware/conditional-get.t`, `t/middleware/etag.t`, `t/response/04-file.t`, `t/app-file.t`, `t/middleware/04-static.t` where relevant.

**Interfaces:** Consume Task 6 APIs. File::Plan gains one private boolean `handle_conditionals` defaulting true; Response::File passes false for an ineligible configured response status. This is an internal planning input, not a new public File option. App::File's ordinary selected-file response remains eligible. File plan itself requires HTTP GET/HEAD for a 304; SSE/WS refusal scope types remain ordinary refusal responses. Range and identity generation interfaces do not change.

- [x] Add a focused File response regression using existing helpers:

```perl
my $root = tempdir(CLEANUP => 1);
my $path = File::Spec->catfile($root, 'conditional.txt');
write_file($path, 'abcdef');
my $response = file_response($path, etag => '"a,b"');
my $events = run_response($response, http_scope(headers => [
    ['If-None-Match', '"old"'], ['If-None-Match', 'W/"a,b"'],
    ['Range', 'bytes=0-1'],
]));
is($events->[0]{status}, 304, 'weak match in second field precedes range');
is($events->[1], {type=>'http.response.body', body=>'', more=>0}, 'bodyless result');
my $error = run_response(file_response($path, status => 404, etag => '"a,b"'),
    http_scope(headers => [['If-None-Match', '*']]));
is($error->[0]{status}, 404, 'file-backed error is not a cached representation');
```

Also assert existing selected file + `etag => 0` + wildcard gives 304; HEAD behaves consistently; POST never gives 304; malformed complete conditions are ignored; no match still follows existing range delivery; offset/length windows keep their current ETag identity; configured validators/cache metadata survive 304. Preserve existing App::File missing/forbidden/path-handling tests.
- [x] Extend ConditionalGet's existing `run_async`/captured-event fixtures with the same comma/repeated/weak/wildcard cases, plus no current ETag and a matching If-Modified-Since. When any If-None-Match field is present, the latter must not produce 304, whether the condition is malformed, empty or nonmatching. Wildcard may match a known eligible representation without an ETag. Errors/redirects, non-GET/HEAD methods and non-HTTP scopes pass through. Keep the post-304 body/trailer suppression regression.
- [x] Run `perlbrew exec --with perl-5.40.0@default prove -l t/middleware/conditional-get.t t/middleware/etag.t t/response/04-file.t t/app-file.t t/middleware/04-static.t` and verify new tests fail for the identified behaviors.
- [x] Implement field-presence and parsed-value handling separately. The intended decision shape is:

```perl
if ($request_headers->has('If-None-Match')) {
    my $condition = $request_headers->if_none_match;
    if (defined $condition) {
        $not_modified = $condition->{any} ? $representation_exists
            : defined($current_etag)
                ? etag_matches($condition, $current_etag, weak => 1) : 0;
    }
} elsif (defined $if_modified_since && defined $last_modified) {
    $not_modified = $self->_not_modified_since($if_modified_since, $last_modified);
}
```

In middleware `$request_headers` wraps scope pairs, `$representation_exists` is established by the eligible response, and `$current_etag` is only supplied to the matcher after successful singleton/grammar validation. Malformed/duplicate application ETags must not be passed into a helper that expects a valid current tag. Retain the existing successful-response gate and explicitly exclude responses without a selected representation (204/205); do not infer existence for errors or redirects. Match exact method names GET/HEAD, not Unicode/case-folded lookalikes.
- [x] In File::Plan, replace first-field equality with all-field parsing and weak matching after selecting/statting the file and calculating its window identity, before Range planning. Add/validate the private boolean and pass it from Response::File based on eligible configured status (2xx excluding204/205). Independently gate on HTTP GET/HEAD. Do not tie conditional eligibility to `handle_ranges`, since callers may disable ranges and still need conditionals. Preserve metadata and use an empty body event; do not invent an ETag when disabled.
- [x] Use `format_etag` for generated tags in both ETag middleware and File::Plan, keeping hashes and window inputs identical. Replace `_valid_entity_tag` with a thin shared-parser adapter or update its two callers; preserve existing explicit File ETag byte-string validation. Remove obsolete parsing helpers only if no caller needs them. Update the File POD's first-field/exact-match claim and ConditionalGet documentation in this same task.
- [x] Run `perlbrew exec --with perl-5.40.0@default prove -lr t/middleware/conditional-get.t t/middleware/etag.t t/middleware/buffered-response.t t/middleware/head-promises.t t/middleware/opaque-body-passthrough.t t/response/04-file.t t/app-file.t t/app-file-resolution.t t/middleware/04-static.t t/protocol-refusal-applications.t t/endpoint/10-sse-decline.t`. Review unchanged range and refusal behavior. Commit `fix: share conditional ETag matching across file responses`.

## Task 8: Examples, complete reference guidance, and final verification

**Files:** Modify `examples/auth-jwt-sandbox/{app.pl,app2.pl,README.md}`, `examples/auth-notes/{app.pl,README.md}`, `examples/auth-extensions/{02-basic-backend.pl,04-response-applications.pl,05-protocol-admission.pl,06-header-primitives.pl,README.md}`, `lib/PAGI/Auth.pm` POD, `lib/PAGI/Tools/{Cookbook,Tutorial}.pod`, `Changes`; reconcile API POD in all touched modules. Extend existing example tests only for newly uncovered integration behavior: `t/integration-auth-jwt-sandbox.t`, `t/integration-auth-notes.t`, `t/auth/11-extension-examples.t`, `t/auth/12-cookbook.t`, `t/00-pod/cookbook-examples.t`. Audit `t/00-load.t` and include the new public module if its explicit module inventory requires it.

**Interfaces:** Examples use existing `unauth_result(failure => {code,message})`; no new failure scalar shortcut or Auth response behavior. All protected-response status/challenge mapping stays explicit application code. Auth's formatter export remains supported; examples of independent header use import from Utils.

**User refinement during execution:** Both JWT sandbox apps define `sub jwt_backend ($request) { ... }` and pass `backend => \&jwt_backend`, matching the examples' named-handler style. Update corresponding README snippets as well.

- [x] Read existing example tests before editing. JWT already checks malformed/duplicate fields as400, invalid token as401, guest challenges, and both app variants. Preserve these assertions instead of adding another broad example suite. Add only an uncovered delegation-relevant case (for example tab-separated Bearer is malformed, or a zero token reaches the verifier rather than becoming absent).
- [x] Replace all three main Bearer extraction blocks with:

```perl
my $token;
my $parsed = eval {
    $token = $request->bearer_token(raise_on_error => 1);
    1;
};
return unauth_result(failure => {
    code => 'malformed_authorization',
    message => 'Expected one Authorization header containing a Bearer token.',
}) unless $parsed;
return unauth_result() unless defined $token;
```

Keep JWT verification and token-store lookup outside this eval. Preserve public-safe failure messages and the existing application-local mapping: malformed presentation400/invalid_request; absent/other scheme401/no error; invalid token401/invalid_token; inadequate scopes403/insufficient_scope. Do not map arbitrary verifier failures into malformed-header responses.
- [x] Update the Basic backend to call `basic_auth(raise_on_error => 1)` in a parsing-only eval, use `defined` username/password, and keep its deliberately documented ASCII identity/password policy in application code. Other schemes/missing fields are guests; failed parsing is a local failure. Replace the simple `'Bearer accepted'` raw comparisons in the response/admission examples with a defined extracted-token comparison without expanding their authentication policy. Keep example06's intentional raw-header construction and extend its independent utility import example.
- [x] Update README descriptions that call Basic permissive or describe handwritten header_all parsing. Update Cookbook/Tutorial backend snippets and Auth's cookbook to delegate extraction. Keep examples that explicitly teach raw construction as escape routes, labeled as such. Add four small cookbook sections using the final APIs: authentication extraction, parameterized upload/download fields, Vary composition, conditional tag comparison. Use multiple small snippets, not another demo application.
- [x] Complete exact per-function/per-method POD for new APIs and fill the existing Headers method reference enough to make raw alternatives directly usable (constructor, get/get_all, writes, output forms). Show arguments, defaults, return shape, missing/empty/malformed distinctions, mutation behavior, byte/character expectations, and a concrete example. No claim that readers produce live views or utility functions accept class invocants. Add a release note under the existing unreleased version, including tighter Request auth parsing, normalized Content-Type and improved conditional matching. Do not rewrite old specs/handoffs; add a successor link only where needed.
- [x] Run the relevant example/documentation gate:

```sh
perlbrew exec --with perl-5.40.0@default prove -lr t/integration-auth-jwt-sandbox.t t/integration-auth-notes.t t/auth t/00-pod/cookbook-examples.t t/integration-maintained-examples-load.t t/distribution-prerequisites.t
```

JWT tests may skip if their documented example-only Crypt::JWT dependency is missing. Record that limitation; do not promote it to a core runtime dependency or claim those cases ran. Use the existing installed dependency if available. No browser exercise is needed.
- [x] Audit remaining occurrences with `rg -n 'bearer_token|basic_auth|header_all\(.Authorization|filename=|boundary=|If-None-Match|_etag_matches|_merge_vary_accept|Vary' lib examples t`, and inspect results. Residual raw examples, MIME framing and intentionally unchanged negotiation/dehop logic are valid; residual independent auth/parameter/ETag parsers in the selected consumers are not. Do not chase unrelated header policy.
- [x] Run POD syntax checks for modified `.pm`/`.pod` files using the installed `podchecker` under the same Perl environment. Run `git diff --check`, then the full repository gate `perlbrew exec --with perl-5.40.0@default prove -lr t`. Report failures against the recorded baseline; do not weaken tests to get a green result. Once the gates pass, do not repeat them without intervening changes or an unresolved concern.
- [x] Review the spec-to-task checklist below, inspect the complete diff for extra abstractions/dependencies and stage only owned changes. Commit `docs: demonstrate shared header helpers in auth and HTTP recipes`. Report commits, actual tests/skips and remaining blockers; don't certify success merely because the plan steps were attempted. No push or merge.

## Review and stop conditions

- Task1: no ambiguity between missing, unsupported and malformed credentials; no secrets in errors; Auth invocation/overrides preserved.
- Task2–4: complete-input parsing, duplicate semantics, upload/download separation, and character-to-byte filename boundary agree with the spec.
- Task5: Vary changes preserve unrelated pairs; default token comparison remains exact.
- Task6–7: no naive comma splitting, no date fallback when If-None-Match exists, no 304 for errors/other methods/refusal protocols, no changes to identity generation or Range policy.
- Task8: examples retain explicit app policy and documentation states the actual shipped API.

If implementation appears to require a parser registry, persistent parsed cache, new public policy option, server coupling, revised body ownership, or expanding precondition handling, stop and explain the concrete conflict. Do not resolve a design conflict with accumulating flags or exception-swallowing. Ordinary internal adapters and local variables described here do not require further approval.

## Spec-to-task coverage and final handoff

| Spec requirement | Task |
| --- | --- |
| Error modes, byte strings, singleton fields, Basic/Bearer, Request delegates, Auth formatter | 1 |
| Parameter grammar, quoting, normalized named readers, empty hash/duplicates | 2 |
| Both Request boundary paths and both multipart readers, limits/ownership preserved | 3 |
| UTF-8 download filename output, explicit extended fallback, File integration | 4 |
| Tokens, membership, Vary, Pages/CORS/GZip, raw/dehop preservation | 5 |
| ETag lexical grammar, lists, strong/weak comparison, Headers methods | 6 |
| File/middleware eligibility, metadata, date precedence, ranges and wildcard without ETag | 7 |
| Auth failure mapping, exact docs, four use cases, migrations, release note and full gate | 8 |

Final handoff should state which APIs and consumers changed, the current branch/commits, focused/full gate results and optional skips. The reviewer should assess mergeability and report blockers, not assume a required positive verdict. This plan is an implementation guide; no runtime work was performed while writing it.
