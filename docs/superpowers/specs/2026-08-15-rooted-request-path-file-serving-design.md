# Rooted Request Paths and Shared File Serving Design

**Date:** 2026-08-15
**Status:** Proposed for written user review

## 1. Purpose

PAGI::Tools currently implements closely related request-path and file-serving
logic in several places:

- `PAGI::App::File`
- `PAGI::App::Directory`
- `PAGI::Middleware::Static`
- `PAGI::Middleware::XSendfile`
- the two chat examples' hand-written static handlers
- a custom-download recipe in the Cookbook

The implementations disagree about hidden files, methods, pass-through, path
normalization, and symbolic links. `File` and `Directory` also use a raw string
prefix comparison after `realpath`; a root such as `/tmp/www` therefore appears
to contain `/tmp/www2`. `Static` has a separate lexical containment algorithm.
XSendfile performs raw prefix replacement and depends on hash iteration order.

This design introduces two narrow path utilities and makes
`PAGI::App::File` the single reusable file-serving engine. `Directory` owns
directory listings. `Static` owns matching, rewriting, and pass-through.
XSendfile owns proxy delegation. None of those outer components reimplements
file response details.

## 2. Goals

The change must:

1. prevent request-controlled path components from escaping the configured
   lexical root;
2. construct paths with Perl's platform-aware `File::Spec` APIs;
3. preserve intentionally configured symbolic links, including links whose
   targets are outside the lexical root;
4. centralize MIME type, ETag, conditional request, range, HEAD, and PAGI
   `file` event behavior in `PAGI::App::File`;
5. give subclasses and first-party composing components a documented result
   seam instead of requiring response capture or duplicated probing;
6. distinguish missing, forbidden, and unexpected operational failures;
7. preserve server-owned file opening and optimized file delivery; and
8. document the actual security boundary without claiming physical
   `realpath` confinement.

Backward compatibility is not a constraint for this unreleased API. Tests,
examples, documentation, and migration notes must nevertheless describe every
intentional behavior and option change.

## 3. Non-goals

This design does not:

- confine a hostile or attacker-writable static tree;
- protect against an administrator deliberately configuring an unsafe root;
- provide an `openat(2)`-style race-free filesystem sandbox;
- open and validate a filehandle in the application;
- replace operating-system permissions or application authorization;
- add asynchronous filesystem APIs;
- add automatic production logging inside file-serving components; or
- turn `PAGI::Utils::app_path` into a request-path validator.

An application that serves from a tree writable by an untrusted principal has
a different threat model. It needs a separately designed hardened facility,
potentially based on directory handles, no-follow semantics, and an async I/O
strategy.

## 4. Threat model and trust boundary

The request author controls the decoded PAGI request path. The application
owner controls:

- the configured filesystem root;
- configured index names and other file options;
- the contents of the rooted filesystem tree; and
- symbolic links reachable through that tree.

Request input must not introduce a parent traversal, alternate separator
traversal, NUL byte, platform volume, or absolute child path that changes the
configured lexical root. Once a request has been converted to validated child
components, the operating system may follow administrator-created symbolic
links normally. A symlink inside the root is intentionally part of the
application owner's authority, even when its target is outside the root.

Consequently, this feature promises **lexical rooted construction**, not
physical containment. Documentation must recommend a dedicated, non-attacker-
writable tree when strict separation is desired and must say plainly that an
outward symlink extends the served tree.

## 5. Architecture

### 5.1 Responsibilities

`PAGI::Utils` supplies two optional functions:

```perl
use PAGI::Utils qw(path_from_root replace_path_prefix);
```

They are included in `:all`. A new `:path` bundle contains `app_path`,
`path_from_root`, and `replace_path_prefix`; none is exported by default.

`path_from_root` validates request-controlled components and constructs a
filesystem pathname. `replace_path_prefix` performs component-aware translation
of an existing path into another namespace. Both are synchronous, lexical,
side-effect-free, and perform no target filesystem inspection. Resolving a
relative input may consult the process working directory through
`File::Spec->rel2abs`.

`PAGI::App::File` owns filesystem inspection and HTTP file serving. It exposes
documented `locate` and `serve` seams and returns request-local
`PAGI::App::File::Result` values.

`PAGI::App::Directory` reuses the File engine. It intercepts only a located
directory without an index and renders a listing. Files, index files, errors,
headers, ranges, and body events remain File behavior.

`PAGI::Middleware::Static` creates and delegates to a File engine. It owns only
scope/method eligibility, path matching and rewriting, and missing-file
pass-through.

`PAGI::Middleware::XSendfile` continues to intercept completed file response
events. It uses `replace_path_prefix` for deterministic, boundary-aware hash
mapping.

### 5.2 Request-local results

`PAGI::App::File::Result` is a small documented value object with no mutator
methods. It has these result kinds:

- `file`
- `directory`
- `missing`
- `forbidden`

It supplies:

```perl
$result->kind;
$result->path;       # may be undef when no safe candidate can be constructed
$result->size;       # defined for a located file
$result->mtime;      # defined for a located file

$result->is_file;
$result->is_directory;
$result->is_missing;
$result->is_forbidden;
```

`path`, `size`, and `mtime` return ordinary scalar values. Callers must not
infer authorization from a pathname. The object exists to communicate one
request's completed resolution and to carry already-obtained metadata into
response generation. It has no global or per-compiled-app mutable state.

The class name and methods above are public subclass seams. Its internal
storage is not public API.

### 5.3 File engine calls

The reusable flow is:

```perl
my $result = $file->locate($request_path);
await $file->serve($scope, $send, $result);
```

`locate` is synchronous. It validates the request path, applies the exact index
selection rules in section 7, inspects the selected filesystem object, and
returns a Result.
The final successful file metadata is retained rather than probed again by
`serve`. Index candidates may each require their own existence check.

`serve` is asynchronous because it emits PAGI events. It accepts any Result:

- `file` receives the normal file response;
- `missing` receives a negotiated `PAGI::Pages` 404;
- `forbidden` receives a negotiated `PAGI::Pages` 403; and
- `directory` receives a negotiated 404 unless a component such as Directory
  intercepts it first.

Callers may inspect and intercept a result before handing it to `serve`.
Static uses this to pass an eligible missing file downstream. Directory uses
it to render an eligible listing. Neither recreates file response generation.

`serve` enforces GET/HEAD when it owns a result. Unsupported HTTP methods
receive a negotiated 405 with `Allow: GET, HEAD`. A component that deliberately
declines a method, such as Static, bypasses the engine before locating a file.
`PAGI::App::File->to_app` and `serve` require an explicit HTTP scope and croak
for another or missing scope type. Static checks its boundary first and passes
non-HTTP scopes downstream without invoking the engine.

## 6. `path_from_root` contract

### 6.1 Signature and result

```perl
my $candidate = path_from_root($root, $request_path);
```

Both arguments must be defined, non-reference strings. The root must be
nonempty. Invalid programmer arguments croak with a message naming the
argument and contract. An empty request path is valid and identifies the root.

The helper returns `undef` for unsafe request input. It returns an absolute,
platform-built pathname for valid input. It performs no existence, type,
permission, symlink, ownership, or containment check.

A relative root is resolved against the current working directory. A
long-lived component such as `PAGI::App::File` resolves and caches its root at
construction, so a later `chdir` cannot alter that component. A direct caller
that repeatedly passes a relative root receives normal current-working-
directory semantics on each call.

### 6.2 Request grammar

The PAGI request path is already decoded. `path_from_root` never percent-
decodes it again.

The helper treats both `/` and `\` as request separators on every platform.
This is intentionally stricter than native Unix filename syntax: a deployment
moved to Windows must not turn previously harmless backslashes into traversal.

After splitting with trailing empty components preserved:

- leading and repeated separators do not select a filesystem root;
- empty components are ignored;
- a single `.` component is ignored;
- a component consisting only of two or more dots is unsafe;
- a NUL byte anywhere is unsafe;
- a component that introduces an absolute path or platform volume is unsafe;
  and
- all remaining components are ordinary relative names.

The all-dot rule deliberately rejects `...` and longer dot-only Unix names.
That conservative cross-platform restriction matches the existing File and
Plack 1.0054 input policy.

The utility itself permits dot-prefixed ordinary names such as `.well-known`.
Hidden-file policy belongs to File.

The helper preserves directory intent. A request ending in a separator or a
final `.` must not become equivalent to a plain file request. The returned
pathname may express that intent with the platform's current-directory
component rather than preserving the caller's literal final slash. For
example, `/manual.pdf/` must fail as a file even when `/manual.pdf` exists.

### 6.3 Platform-aware construction

The configured root is normalized with:

```perl
File::Spec->canonpath(File::Spec->rel2abs($root));
```

Only after request validation are components joined with
`File::Spec->catfile` or the directory-intent equivalent. The helper does not
concatenate a platform separator manually.

`File::Spec` provides platform-aware construction; it is not the security
validator. `canonpath` does not promise symlink resolution or physical
containment. `File::Basename` is not required because this operation assembles
validated components rather than splitting a preexisting path. Where path
parsing is needed, `File::Spec`'s `splitpath` and `splitdir` are preferred.

### 6.4 Examples

```perl
path_from_root('/srv/myapp/static', '/css/app.css');
# platform form of /srv/myapp/static/css/app.css

path_from_root('/srv/myapp/static', '/../secrets.txt');
# undef

path_from_root('/srv/myapp/static', '/images\..\secrets.txt');
# undef

path_from_root('/srv/myapp/static', '/.well-known/security.txt');
# valid; File's allow_hidden policy decides whether it may be served
```

## 7. File location policy

Each File object normalizes and caches its configured root during construction.
Construction does not require the root to exist and does not call `realpath`.

`allow_hidden` is accepted by File and defaults to false. A request component
whose first character is `.` is forbidden unless it is the ignored single-dot
component or hidden paths are enabled. Directory and Static pass the same
option to the same engine. Directory's current `show_hidden` option is removed;
`allow_hidden` governs both listing and serving.

For a safe candidate, `locate` classifies results as follows:

- a regular readable file is `file`;
- a directory with a selected configured index resolves to that index as
  `file`;
- a directory without an index is `directory`;
- a nonexistent path, a non-regular non-directory object, `ENOENT`, or
  `ENOTDIR` is `missing`;
- a hidden-policy rejection, unsafe request path, unreadable file, `EACCES`, or
  `EPERM` is `forbidden`; and
- an unexpected inspection failure croaks and preserves the operational error
  for the enclosing error middleware.

Index names are examined in declared order. A hidden index is ineligible while
`allow_hidden` is false. A missing or non-regular index candidate does not end
the search. The first regular candidate ends the search: it becomes `file` when
readable and `forbidden` when unreadable. If no candidate is selected, the
original directory remains `directory`. These rules prevent a later index from
silently bypassing an earlier existing-but-forbidden one.

The implementation should use one final metadata record for the selected file
and reuse it for size, mtime, ETag, and response headers. It must not add an
application-side `open` merely to close a race or inspect an open handle.

There remains a normal pathname race between inspection and the server opening
the PAGI `file` event. That is acceptable under the trusted-tree threat model.

## 8. HTTP and composition behavior

### 8.1 File

File owns HTTP GET and HEAD requests. Other HTTP methods receive 405 with
`Allow: GET, HEAD`. A located file preserves existing conditional request,
ETag, MIME type, range, and content-length behavior. GET emits a PAGI body
event with `file`. HEAD emits the corresponding headers and no file or body
bytes.

Missing, forbidden, method-not-allowed, and invalid-range responses use
`PAGI::Pages`; the components do not maintain private default-page bodies.

### 8.2 Directory

Directory uses File for method validation, path policy, index selection, file
responses, and error responses. It renders only a `directory` result.

GET emits the listing. HEAD emits the same status and calculated headers as
GET without listing-body bytes. POST and other unsupported methods receive 405
rather than the current successful listing.

`allow_hidden => 0` excludes hidden entries from listings and forbids direct
retrieval. `allow_hidden => 1` enables both.

### 8.3 Static

Static remains opportunistic middleware:

- non-HTTP scopes pass downstream;
- non-GET/HEAD methods pass downstream;
- a path that does not match the configured matcher passes downstream;
- a matching file delegates to File;
- a matching missing path or indexless directory passes downstream only when
  `pass_through` is true, otherwise it receives 404; and
- an unsafe or hidden path receives 403 and never passes downstream.

This preserves the distinction between a standalone application that owns its
request and middleware that may decline handling it.

### 8.4 Errors and logging

File, Directory, and Static do not emit production log records for ordinary
404 or 403 outcomes. Access logging observes the final status once. Unexpected
failures propagate so the enclosing ErrorHandler can report them and render a
safe 500.

The existing development-only File diagnostic that prints the attempted
candidate path remains. It is configuration assistance, not access logging,
and it must not change response behavior. Unsafe input for which no candidate
can be built need not produce an attempted-path diagnostic.

## 9. `replace_path_prefix` and XSendfile

### 9.1 Utility contract

```perl
my $mapped = replace_path_prefix($path, $from, $to);
```

All three arguments must be defined, non-reference, nonempty strings. Invalid
programmer arguments croak.

The function makes `$path` and `$from` absolute relative to the current working
directory, then normalizes them lexically with `File::Spec`. They must resolve
to the same platform volume to match. The function performs no filesystem I/O.
A match occurs only when `$path` equals `$from` or is a descendant at a
path-component boundary. Matching follows the current platform's
case-tolerance rules. `/var/www/files-old` therefore does not match
`/var/www/files`.

On a match, the unmatched source components are appended to `$to` without a
doubled or omitted separator. The replacement namespace is slash-oriented so
it is suitable for X-Accel-Redirect internal URIs. Source platform separators
are converted to `/` in the appended suffix. The function returns `undef` when
the source prefix does not match.

### 9.2 Hash mappings

XSendfile evaluates hash mapping prefixes by descending normalized prefix
length, with lexical order as the deterministic tie breaker. The most specific
component-aware match wins:

```perl
mapping => {
    '/srv/files'         => '/internal/files',
    '/srv/files/private' => '/internal/private',
}
```

`/srv/files/private/a.pdf` maps through `/srv/files/private` regardless of
Perl hash order.

When a hash mapping is configured but no prefix matches, XSendfile declines
interception and forwards the original PAGI response events. It must not place
an unmatched absolute filesystem pathname in an X-Accel-Redirect header.

The existing no-mapping behavior for X-Sendfile and Lighttpd remains: the
filesystem path is used directly. The scalar mapping form remains a simple
slash-clean prefix applied to the whole source path.

XSendfile validates every configured replacement prefix at construction as a
safe header fragment and validates the completed mapped value before emitting
it. A configured value containing NUL, CR, LF, or another prohibited header
control byte croaks during construction. A request-derived suffix that makes a
completed value invalid causes XSendfile to decline interception and forward
the original file event. `replace_path_prefix` itself remains a path utility;
header-value policy belongs to XSendfile.

## 10. Server boundary and performance

PAGI file body events support `file` and `fh`. This design keeps `file` as the
normal output. The server opens and closes the path and may use sendfile,
worker-pool I/O, X-Sendfile, or another optimized strategy.

The application does not open a filehandle merely to validate it. Such an open
would add synchronous blocking, transfer handle ownership to the application,
and reduce the server's freedom to choose an optimized implementation.

The new path utilities perform no target inspection or mutation; relative
inputs may consult the current working directory. Location retains the
filesystem probes inherently required to identify files, directories, indexes,
permissions, size, and mtime. The selected file's metadata is reused rather
than re-statted during response generation.

## 11. Documentation and examples

The implementation updates:

- File, Directory, Static, XSendfile, and Utils POD;
- the Cookbook's custom-download guidance;
- the two chat examples with hand-written static serving;
- any other first-party example that demonstrates the affected options or
  duplicated path checks;
- the upgrade guide; and
- Changes.

The chat examples delegate static requests to `PAGI::App::File`; they do not
replace one manual traversal algorithm with a call to `path_from_root` followed
by another hand-written file server.

Documentation must include:

- `path_from_root` examples and hostile-input behavior;
- the distinction between lexical rooted construction and `realpath`
  confinement;
- the trusted-root and symlink authority model;
- dedicated-root and filesystem-permission best practices;
- `allow_hidden` behavior and the `show_hidden` migration;
- Static's method and pass-through behavior;
- default Pages responses and logging ownership;
- the `file` rather than `fh` performance boundary; and
- component-aware XSendfile mappings.

Existing claims that File or Directory prevent symlink escape must be removed.
The prior release-blocker wording should be closed as corrected request-input
validation plus a clarified threat model, not as physical symlink confinement.

The upgrade guide must identify these observable changes:

- File's NUL-path response changes from 400 to the common unsafe-path 403;
- an administrator-created outward symlink is now served deliberately rather
  than rejected by File or Directory;
- Directory returns 405 instead of a successful listing for unsupported
  methods;
- a missing Directory candidate becomes 404 rather than the old failed-
  `realpath` 403;
- Static now denies hidden paths by default;
- Directory's `show_hidden` option becomes the shared `allow_hidden` option;
- XSendfile hash mappings use component boundaries and most-specific order;
  and
- an unmatched XSendfile hash mapping falls back to the original PAGI file
  event instead of exposing the unmatched path in the proxy header.

## 12. Verification

### 12.1 Utility tests

`path_from_root` tests cover:

- absolute and relative roots;
- normal files and directories;
- repeated and leading separators;
- single-dot components;
- empty paths;
- trailing separators and final-dot directory intent;
- NUL;
- `..`, `...`, and longer all-dot components;
- forward, backslash, and mixed separators;
- absolute-child and platform-volume attempts;
- valid ordinary dotfiles; and
- invalid programmer argument diagnostics.

Expected paths are constructed with `File::Spec`, not Unix-only literal
strings. Platform-specific assertions are conditioned on the platform's
reported path behavior.

`replace_path_prefix` tests cover exact matches, descendants, false sibling
prefixes, unmatched paths, replacement joining, source separators, platform
case behavior, and invalid arguments.

### 12.2 File engine tests

Tests cover:

- every Result kind and predicate;
- result isolation across concurrent requests;
- selected-file metadata reuse;
- GET and HEAD parity;
- MIME type, ETag, 304, ranges, 416, and content length;
- negotiated Pages 403, 404, and 405 responses;
- exact `Allow: GET, HEAD` behavior;
- hidden paths disabled and enabled;
- missing, non-regular, unreadable, and unexpected-error classification;
- directory index selection;
- directory-intent requests against regular files;
- development diagnostics without response changes;
- propagation of unexpected errors to ErrorHandler; and
- emitted `file` events with no application-opened `fh`.

A temporary root containing a symlink to an outside fixture must successfully
serve that fixture. This is a positive contract test, not an omitted security
case.

### 12.3 Directory and Static tests

Tests establish that File, Directory, and Static produce the same headers,
ETags, ranges, HEAD semantics, and body-file event for the same file.

Directory tests cover index delegation, listing GET/HEAD, 405 on unsupported
methods, and consistent hidden listing/retrieval.

Static tests cover scope and method bypass, matcher decline, rewritten paths,
missing and indexless-directory pass-through, non-pass-through 404, forbidden
non-pass-through, and File response parity.

### 12.4 XSendfile tests

Tests cover exact and descendant hash mappings, rejection of false prefix
siblings, longest-prefix selection independent of hash order, deterministic
ties, scalar mapping, unmatched-hash decline, direct no-mapping behavior, and
preservation of partial-response bypass. They also cover constructor rejection
of unsafe configured header fragments and safe decline when a mapped suffix
cannot be represented as a header value.

### 12.5 Integration and documentation tests

The updated chat examples must load and serve their static fixtures through
File. Integration tests request the pages and follow their referenced static
assets where practical; checking helper strings alone is insufficient.

A final scoped search over `lib/`, `t/`, `examples/`, the Cookbook, upgrade
documentation, and Changes must find no obsolete symlink-confinement claim,
no first-party manual `..` deletion used as a file-serving boundary, and no
use of `show_hidden`.

## 13. Rejected alternatives

### 13.1 Canonical-root containment

Resolving both root and target with `realpath` and requiring physical
containment would prevent useful administrator-created links that intentionally
share assets across projects. It would also retain a pathname race unless the
opened handle became the true authority. That is not the selected contract.

### 13.2 Open, validate, and serve a filehandle

Opening first and validating `stat $fh` is stronger against pathname races and
is used by some file servers. In PAGI it adds synchronous blocking to the
application and moves ownership away from the server's optimized `file` event.
It is disproportionate to the trusted-tree threat model.

### 13.3 Two complete file servers sharing only helpers

Giving File and Static the same path helper while leaving each to implement
ranges, ETags, MIME types, and response events would preserve most current
duplication and allow behavior to drift again. File is therefore the shared
engine, not merely one utility consumer among several independent servers.

### 13.4 A general filesystem resolver service

A configurable resolver object could combine policy, probing, caching, and
authorization. The present requirements need one pure path constructor and one
File result seam. A larger abstraction adds lifecycle and extension questions
without a current consumer.

### 13.5 Adopting Plack::App::File unchanged

Current Plack input parsing provides useful precedent: it rejects NUL and
all-dot parent-like components and constructs paths beneath a root. It does not
enforce physical symlink containment; an administrator-created outward symlink
can be served. That matches this design's trust decision. PAGI cannot adopt the
implementation directly because PAGI has async events, explicit `file` body
events, Pages responses, shared Directory/Static composition, and its own HEAD
boundary.

## 14. Implementation scope

The expected production scope is:

- `lib/PAGI/Utils.pm`
- `lib/PAGI/App/File.pm`
- a small `PAGI::App::File::Result` value class
- `lib/PAGI/App/Directory.pm`
- `lib/PAGI/Middleware/Static.pm`
- `lib/PAGI/Middleware/XSendfile.pm`
- affected tests, examples, POD, Cookbook, upgrade documentation, and Changes

No router, Context, Response, server, or PAGI protocol change is required.
