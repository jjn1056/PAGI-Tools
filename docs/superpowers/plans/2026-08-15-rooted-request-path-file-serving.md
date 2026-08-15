# Rooted Request Paths and Shared File Serving Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Block request-controlled lexical path traversal, preserve trusted
symlinks, and make `PAGI::App::File` the one file-serving engine reused by
Directory and Static while fixing XSendfile prefix mapping.

**Architecture:** `PAGI::Utils` gains two side-effect-free synchronous path
functions.
`PAGI::App::File` separates request-local location into a small Result value
from asynchronous HTTP emission; Directory intercepts only directory results,
Static intercepts only middleware decline/pass-through outcomes, and XSendfile
uses a separate component-aware mapping utility. Servers continue to receive
PAGI `file` events and remain responsible for opening files.

**Tech Stack:** Perl 5.18-compatible distribution code, core `File::Spec`,
`Fcntl`, `Errno`, `Future`, `Future::AsyncAwait`, `PAGI::Pages`,
`PAGI::Routing::HeadBoundary`, `PAGI::Test::Client`, `Test2::V0`, POD,
Markdown, and Dist::Zilla. No new dependency.

## Global Constraints

- The approved contract is
  `docs/superpowers/specs/2026-08-15-rooted-request-path-file-serving-design.md`.
  If implementation evidence conflicts with it, record a deviation and obtain
  the user's decision before dependent work continues.
- Backward compatibility is not required. Do not retain `show_hidden`, the
  physical-symlink rejection, the NUL-specific 400, Directory's POST listing,
  or XSendfile's raw unmatched-hash fallback as aliases or compatibility modes.
- Work only in
  `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` or an isolated
  worktree created for this repository by the Superpowers worktree workflow.
- Preserve unrelated untracked files and existing `.superpowers/` state. Never
  stage them. Stage only files named by the current task; never use
  `git add .` or `git add -A`.
- Keep distribution code and ordinary tests compatible with Perl 5.18. Avoid
  signatures, postfix dereferencing, `try`/`catch`, and newer syntax. Check
  changed Perl files under the available Perl 5.16.3 as a stricter syntax gate.
- Add no CPAN dependency. `File::Spec`, `Fcntl`, and `Errno` are core.
- `path_from_root` and `replace_path_prefix` perform no target inspection or
  mutation: no `stat`, file test, `open`, `realpath`, network operation,
  subprocess, Future, or environment mutation. Relative inputs may consult the
  process working directory through `File::Spec->rel2abs`.
- Request validation treats both `/` and `\` as separators on every OS,
  rejects NUL and dot-only components of length at least two, ignores empty and
  single-dot components, and rejects a child volume or absolute child path.
- `path_from_root` permits ordinary dotfiles. `PAGI::App::File` alone applies
  `allow_hidden`, which defaults to false and governs File, Directory, and
  Static serving/listing consistently.
- Do not call `realpath` to enforce containment. Administrator-created symlinks
  inside the configured root are trusted authority and may target another
  filesystem tree.
- Do not open a filehandle in File, Directory, or Static. Successful GET body
  events use `file`; HEAD preserves equivalent headers and sends no file/body
  bytes.
- Location is synchronous and request-local. Reuse the selected file's size and
  mtime in serving; do not re-stat it. Index candidates may each be probed.
- Missing becomes Pages 404, forbidden becomes Pages 403, unsupported owned
  methods become Pages 405 with `Allow: GET, HEAD`, and unexpected inspection
  errors propagate to ErrorHandler.
- File/Directory/Static do not add production logging. Retain only File's
  existing development-only attempted-candidate diagnostic.
- Static remains opportunistic: non-HTTP, non-GET/HEAD, and unmatched paths
  bypass; eligible missing/indexless results obey `pass_through`; forbidden
  results never pass through.
- XSendfile hash mappings are component-aware and most-specific-first. An
  unmatched or request-derived header-unsafe mapping declines interception and
  forwards the original events.
- Use TDD for every behavior: write focused assertions, run and record the RED,
  implement, rerun GREEN, then run the task gate.
- Use `PAGI::Test::Client` for complete HTTP behavior. Use direct event
  recorders for exact `file`/`fh` ownership, HEAD wire events, non-HTTP errors,
  or XSendfile interception/decline.
- Capture expected failures with `dies` and assert stable semantic fragments,
  not Perl file/line suffixes. Expected test output is warning-free except for
  a specifically asserted warning contract.
- Every implementation task ends in one focused commit and independent review.
  The coordinator verifies the diff, command output, SHA, and ledger row before
  the next task starts.
- Run the repository-wide `prove -lr t` suite once at the final reviewed HEAD.
  Focused tests may run as TDD requires. Do not run `dzil test`, which repeats
  the suite. If the final suite finds a defect and HEAD changes, record it and
  run one fresh final suite at corrected HEAD.
- Run project tests with Perl 5.42.2:

  ```bash
  /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-rooted-paths.t'
  ```

## Execution Tracking and Work Map

Before Task 1, create an isolated worktree with the selected execution skill.
The expected branch name is `feat/rooted-file-serving`. No push or deployment
is authorized.

When using subagent-driven development, create its workspace with:

```bash
/Users/jnapiorkowski/.codex/plugins/cache/openai-curated-remote/superpowers/6.2.0/skills/subagent-driven-development/scripts/sdd-workspace docs/superpowers/plans/2026-08-15-rooted-request-path-file-serving.md
```

The command must print a directory ending in
`.superpowers/sdd/2026-08-15-rooted-request-path-file-serving`. Create
`progress.md` there with this structure:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-08-15-rooted-request-path-file-serving.md

## Repository work map

| Repository path | Ticket / work item | Branch | Base branch / commit | Owned changes | Deployment boundary | Push target |
|---|---|---|---|---|---|---|
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools/.worktrees/rooted-file-serving` | Approved `2026-08-15-rooted-request-path-file-serving` plan; no external ticket | `feat/rooted-file-serving` | `main` at the exact recorded starting HEAD | Tasks 1–8 in this plan only | PAGI-Tools distribution source, tests, examples, and docs; no deployment or external mutation | None authorized; local branch only |

| Task | Status | Commit range | Focused verification | Full-suite verification | Review |
|---|---|---|---|---|---|
| 1 | pending | — | — | deferred to Task 8 | — |
| 2 | pending | — | — | deferred to Task 8 | — |
| 3 | pending | — | — | deferred to Task 8 | — |
| 4 | pending | — | — | deferred to Task 8 | — |
| 5 | pending | — | — | deferred to Task 8 | — |
| 6 | pending | — | — | deferred to Task 8 | — |
| 7 | pending | — | — | deferred to Task 8 | — |
| 8 | pending | — | — | final gate | — |

## Deviations

| ID | Status | Conflicting plan text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

Before Task 1, record the exact output of `git rev-parse HEAD` in
`starting-head` and `progress.md`, plus `git status --short` and the focused
baseline commands. Reconfirm the one-repository work map after any approved
architecture or scope change and before any push request.

The coordinator owns the ledger. In the same work step as each task commit and
review, record exact commit SHAs, commands, exit statuses, real test counts,
elapsed time, and review findings. Never substitute an estimated count or an
unsupported worker summary.

Contract conflicts receive sequential IDs `DEV-001`, `DEV-002`, and so on,
status `awaiting decision`, exact conflicting text, evidence, and blocked
tasks. Record the user's decision before dependent work resumes. An ordinary
bug whose fix preserves the approved contract is not a deviation.

## File and Responsibility Map

- `lib/PAGI/Utils.pm`: side-effect-free path parsing/construction, prefix
  replacement, exports, and POD. It performs no target inspection.
- `lib/PAGI/App/File/Result.pm`: request-local location value and predicates;
  no HTTP logic or mutable global state.
- `lib/PAGI/App/File.pm`: root/options, location inspection, index selection,
  development candidate diagnostic, Pages outcomes, conditional/range/HEAD
  response generation, and `file` body events.
- `lib/PAGI/App/Directory.pm`: safe escaped directory listing only; delegates
  location, files, indexes, methods, and Pages errors to File.
- `lib/PAGI/Middleware/Static.pm`: scope/method/path eligibility, rewrite, and
  missing pass-through only; delegates owned outcomes to File.
- `lib/PAGI/Middleware/XSendfile.pm`: response interception, deterministic
  configured mapping selection, header-safety gate, and event fallback.
- `t/utils-rooted-paths.t`: public pure utility contract.
- `t/app-file-resolution.t`: Result and synchronous location policy.
- `t/app-file.t`: File HTTP behavior, diagnostics, and existing app_path
  constructor behavior.
- `t/34-directory-security.t`: Directory listing/delegation contract.
- `t/middleware/04-static.t`: Static eligibility/pass-through and File parity.
- `t/middleware/15-xsendfile.t`: mapping/interception/header-safety contract.
- `t/integration-chat-compose.t` and
  `t/integration-websocket-chat-v2.t`: real chat HTML/static asset requests and
  removal of hand-written file servers.
- public POD, `lib/PAGI/Tools/Tutorial.pod`,
  `lib/PAGI/Tools/Cookbook.pod`, `lib/PAGI/Tools.pm`, `README.md`,
  `UPGRADING.md`, `Changes`, and affected example READMEs: threat model,
  examples, migration, and cross-links.

---

### Task 1: Add Rooted-Path Utilities

**Files:**
- Modify: `lib/PAGI/Utils.pm`
- Create: `t/utils-rooted-paths.t`

**Interfaces:**
- Produces: `path_from_root($root, $request_path) -> $absolute_path|undef`
- Produces: `replace_path_prefix($path, $from, $to) -> $slash_path|undef`
- Produces: `:path` export tag containing `app_path`, `path_from_root`, and
  `replace_path_prefix`; both new functions remain optional and join `:all`.
- Consumes: core `File::Spec`; no later task may reimplement traversal or
  component-boundary prefix checks.

- [ ] **Step 1: Write utility export and validation tests**

Create `t/utils-rooted-paths.t` with focused Test2 cases. Build expected values
through `File::Spec` and test both direct imports and `:path`:

```perl
use strict;
use warnings;
use Test2::V0;
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use lib 'lib';
use PAGI::Utils qw(path_from_root replace_path_prefix);

my $root = tempdir(CLEANUP => 1);
is(
    path_from_root($root, '/css/app.css'),
    File::Spec->catfile(File::Spec->canonpath(File::Spec->rel2abs($root)),
        'css', 'app.css'),
    'ordinary request components are rooted with File::Spec',
);

ok(!defined path_from_root($root, '/../secret'),
    'parent traversal is unsafe');
ok(!defined path_from_root($root, '/a\\..\\secret'),
    'backslash traversal is unsafe on every platform');
ok(!defined path_from_root($root, '/.../secret'),
    'longer all-dot components are unsafe');
ok(!defined path_from_root($root, "/bad\0name"),
    'NUL is unsafe');

ok(defined path_from_root($root, '/.well-known/security.txt'),
    'the pure utility does not impose hidden-file policy');
```

Add rows for empty path, leading/repeated/mixed separators, ignored `.`, final
slash and final-dot directory intent, invalid references/undef/empty root,
current-platform volume/absolute component behavior, and relative roots before
and after a controlled `chdir` with the original directory restored.
For the volume row, inspect `File::Spec->splitpath('C:')`: when the current
platform reports a volume, the request component is unsafe; otherwise assert
that the literal component remains beneath the root and never resets it.

- [ ] **Step 2: Write prefix-replacement tests**

Add exact, descendant, false-sibling, relative, case-tolerance, replacement
joining, and invalid-argument rows:

```perl
is(
    replace_path_prefix('/var/www/files/report.pdf',
        '/var/www/files', '/protected'),
    '/protected/report.pdf',
    'descendant suffix is appended in the replacement namespace',
);
is(
    replace_path_prefix('/var/www/files', '/var/www/files', '/protected'),
    '/protected',
    'exact prefix maps without a synthetic trailing component',
);
ok(!defined replace_path_prefix('/var/www/files-old/report.pdf',
        '/var/www/files', '/protected'),
    'a textual prefix outside a component boundary does not match');
```

Condition the case-sensitive/case-tolerant expected result on
`File::Spec->case_tolerant`; do not hard-code Unix semantics.

- [ ] **Step 3: Run RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-rooted-paths.t'
```

Expected: FAIL at compile/import time because the two functions and `:path`
tag do not exist. Record the exact output in the task report.

- [ ] **Step 4: Implement validation and File::Spec construction**

In `PAGI::Utils`, add `@PATH_EXPORTS`, update `@EXPORT_OK`/`%EXPORT_TAGS`, and
implement private argument/component helpers plus the two public functions.
The path builder must follow this shape:

```perl
sub path_from_root {
    my ($root, $request_path) = @_;
    _require_path_string('path_from_root root', $root, 1);
    _require_path_string('path_from_root request path', $request_path, 0);

    my ($parts, $directory_intent) =
        _validated_request_parts($request_path);
    return undef unless defined $parts;

    my $absolute_root = File::Spec->canonpath(
        File::Spec->rel2abs($root),
    );
    my $candidate = @$parts
        ? File::Spec->catfile($absolute_root, @$parts)
        : $absolute_root;

    return $candidate unless $directory_intent && @$parts;
    return File::Spec->catfile($candidate, File::Spec->curdir);
}
```

`_validated_request_parts` must split with `split m{[\\/]}, $path, -1`,
reject `\A\.{2,}\z`, NUL, and current-platform volume/absolute components,
ignore empty and `.`, and preserve directory intent for a final separator or
final `.`.

Implement `replace_path_prefix` by normalizing both source values with
`rel2abs`/`canonpath`, rejecting different volumes, deriving
`File::Spec->abs2rel($path, $from)`, and rejecting a relative result containing
an upward component. Convert accepted suffix components to `/` and join them
to a slash-clean `$to`. Do not call a filesystem operation.

- [ ] **Step 5: Run GREEN and compatibility gates**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-rooted-paths.t t/utils-app-path.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c lib/PAGI/Utils.pm && perl -Ilib -c t/utils-rooted-paths.t'
git diff --check
```

Expected: all PASS; the existing `app_path` contract remains unchanged.

- [ ] **Step 6: Document and commit**

Add Utils POD for both functions, unsafe-`undef` versus programmer-croak,
directory intent, no I/O, symlink non-policy, and the `:path` tag. Stage exactly
the two task files and commit:

```bash
git add lib/PAGI/Utils.pm t/utils-rooted-paths.t
git commit -m "feat: add rooted path utilities"
```

Update Task 1's ledger row with RED/GREEN evidence and review before Task 2.

---

### Task 2: Add File Results and Synchronous Location

**Files:**
- Create: `lib/PAGI/App/File/Result.pm`
- Modify: `lib/PAGI/App/File.pm`
- Modify: `t/00-load.t`
- Create: `t/app-file-resolution.t`

**Interfaces:**
- Consumes: `PAGI::Utils::path_from_root` from Task 1.
- Produces: `PAGI::App::File::Result->kind/path/size/mtime` and
  `is_file/is_directory/is_missing/is_forbidden`.
- Produces: `$file->locate($request_path) -> PAGI::App::File::Result`.
- Produces internal `_probe_path($path) -> { stat => \@stat, readable => 0|1 }
  | { errno => $number, error => $string }`, one immutable snapshot of `stat`
  success or captured errno, so tests can force every classification.
- Task 3 consumes Result metadata without another `stat`.

- [ ] **Step 1: Write Result value tests**

Create `t/app-file-resolution.t`. Assert constructor validation, accessors,
predicates, no mutators, and independent references:

```perl
my $result = PAGI::App::File::Result->new(
    kind => 'file', path => '/tmp/a', size => 10, mtime => 20,
);
is($result->kind, 'file');
ok($result->is_file);
ok(!$result->is_missing);
is($result->size, 10);
like(dies { PAGI::App::File::Result->new(kind => 'other') },
    qr/result kind.*file.*directory.*missing.*forbidden/i);
```

Retain both result references while asserting request isolation; do not compare
only potentially reusable numeric addresses.

- [ ] **Step 2: Write location-policy tests**

Build a temporary root containing a normal file, directory, ordered indexes,
dotfile, non-regular object where supported, and missing names. Assert:

```perl
my $files = PAGI::App::File->new(root => $root);
my $found = $files->locate('/plain.txt');
ok($found->is_file);
is($found->path, File::Spec->catfile($root_abs, 'plain.txt'));
is($found->size, 5);

ok($files->locate('/missing.txt')->is_missing);
ok($files->locate('/empty-dir')->is_directory);
ok($files->locate('/../secret')->is_forbidden);
ok($files->locate('/.secret')->is_forbidden);
ok(PAGI::App::File->new(root => $root, allow_hidden => 1)
    ->locate('/.secret')->is_file);
```

Add tests for index declaration order, hidden indexes, unreadable first index,
directory-intent against a regular file, cached relative root across `chdir`,
ENOENT/ENOTDIR missing, and EACCES/EPERM forbidden. Override `_probe_path` with
the exact documented snapshot shape to make each errno deterministic, including
an `EIO` snapshot whose `simulated probe failure` message propagates. Permission-
dependent real-filesystem cases may skip only when the running platform/user
cannot create the condition; the override still covers classification logic.

- [ ] **Step 3: Add the positive outward-symlink contract test**

Create a file outside the temporary root and a symlink inside it. When symlink
creation is available, assert `locate('/shared.txt')` is `file`, retains the
lexical in-root path, and reads the outside file when served in Task 3. Skip
with the concrete OS error only when symlinks cannot be created.

- [ ] **Step 4: Run RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-file-resolution.t t/00-load.t'
```

Expected: FAIL because Result and `locate` do not exist.

- [ ] **Step 5: Implement Result and root configuration**

Create a classic Perl value class with a validated constructor and read-only
methods. Do not expose its hash layout. In `PAGI::App::File->new`, replace
`realpath` with cached lexical normalization and store `allow_hidden`:

```perl
my $root = exists $args{root} ? $args{root} : '.';
croak 'File root must be a defined, nonempty, non-reference string'
    unless defined($root) && !ref($root) && length($root);

my $absolute_root = File::Spec->canonpath(File::Spec->rel2abs($root));
my $self = bless {
    root          => $absolute_root,
    allow_hidden  => $args{allow_hidden} ? 1 : 0,
    default_type  => $args{default_type} // 'application/octet-stream',
    index         => $args{index} // ['index.html', 'index.htm'],
    handle_ranges => $args{handle_ranges} // 1,
}, $class;
```

Validate `index` as an arrayref of defined non-reference strings. Do not
resolve or open the root at construction.

- [ ] **Step 6: Implement `locate` and error classification**

Use `path_from_root`, then apply hidden policy to request components. Probe
with `stat` through `_probe_path`, classify file/directory using core `Fcntl`
mode helpers, and preserve captured errno immediately. Use these exact groups:

```perl
return _result('missing',   $path) if $errno == ENOENT || $errno == ENOTDIR;
return _result('forbidden', $path) if $errno == EACCES || $errno == EPERM;
croak "Cannot inspect file candidate '$path': $message";
```

For directories, examine indexes in order. Skip missing/non-regular and hidden-
ineligible candidates; stop on the first regular candidate, returning file if
readable and forbidden if unreadable. Return the original directory otherwise.
Call `_development_file_attempt` once for the final safe candidate, after index
selection. Traversal, NUL, and hidden rejection stay silent even when
`PAGI_ENV` is invalid.

- [ ] **Step 7: Run GREEN and compatibility gates**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-file-resolution.t t/app-file.t t/00-load.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c lib/PAGI/App/File/Result.pm && perl -Ilib -c lib/PAGI/App/File.pm && perl -Ilib -c t/app-file-resolution.t'
git diff --check
```

Expected: all PASS. Task 2 adds the new location API without switching `to_app`;
the old NUL and symlink wire outcomes remain unchanged until Task 3.

- [ ] **Step 8: Document and commit**

Add File POD for `allow_hidden`, `locate`, Result methods, trusted symlinks, and
the synchronous/no-open boundary. Add Result to `t/00-load.t`. Stage exactly
the four task files and commit:

```bash
git add lib/PAGI/App/File/Result.pm lib/PAGI/App/File.pm t/00-load.t t/app-file-resolution.t
git commit -m "feat: add file location results"
```

Update Task 2's ledger row and review before Task 3.

---

### Task 3: Serve Every File Outcome Through the Shared Engine

**Files:**
- Modify: `lib/PAGI/App/File.pm`
- Modify: `t/app-file.t`
- Modify: `t/app-file-resolution.t`

**Interfaces:**
- Consumes: Result and `locate` from Task 2.
- Produces: `async $file->serve($scope, $send, $result)` for every Result kind.
- Produces: `to_app` as the thin explicit-HTTP/method/location/serve adapter.
- Preserves: app_path constructor, MIME map, ETag, 304, ranges, Pages fields,
  development diagnostic, and PAGI `file` body events.

- [ ] **Step 1: Update the existing outcome tests to the approved contract**

In `t/app-file.t`, change NUL from 400 to negotiated 403 and the outward
symlink from rejected 403 to successful content. Keep assertions that error
bodies do not disclose request or filesystem paths. Add HEAD for a successful
file, missing file, forbidden path, 405, and 416, asserting headers match GET
and no body/file bytes are emitted.

- [ ] **Step 2: Add direct `serve` and metadata-reuse tests**

Use a direct event recorder and a local File subclass whose `_probe_path`
increments a counter. Call `locate`, then `serve`, and assert no new probe:

```perl
my $result = $component->locate('/sample.txt');
my $after_locate = $component->probe_count;
my @events;
$component->serve($scope, sub {
    push @events, $_[0];
    return Future->done;
}, $result)->get;
is($component->probe_count, $after_locate,
    'serve reuses located metadata without another stat');
is($events[1]{file}, $result->path, 'GET delegates opening to the server');
ok(!exists $events[1]{fh}, 'application does not open a filehandle');
```

Add direct rejection for missing/extension scope type before events, wrong
Result objects, and two interleaved request Futures proving that events and
Result metadata do not cross requests.

- [ ] **Step 3: Run RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-file.t t/app-file-resolution.t'
```

Expected: FAIL on missing `serve` integration and old to_app outcomes.

- [ ] **Step 4: Refactor `to_app` and implement `serve`**

`to_app` must require explicit `type => 'http'`, reject missing/other types,
avoid location work for unsupported methods, call `locate` once, and await
`serve`. `serve` validates scope/method and Result, then:

```perl
return await _respond_page($scope, $send, 'not_found')
    if $result->is_missing || $result->is_directory;
return await _respond_page($scope, $send, 'forbidden')
    if $result->is_forbidden;
```

For unsupported owned methods, call Pages `method_not_allowed` with
`allow => [qw(GET HEAD)]`. Install the idempotent
`PAGI::Routing::HeadBoundary->prepare($scope, $send)` inside `serve` before any
Pages or file response so direct use, routers, and Compose all suppress HEAD
exactly once while retaining calculated headers.

Move the current conditional, MIME, range, and event logic to the file branch.
Use Result `size`, `mtime`, and `path`; do not `stat`, `realpath`, or `open`.
Use `Future->wrap` around `Response->respond($send)` so immediate and Future
completion both work.

- [ ] **Step 5: Run GREEN and focused regressions**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/app-file.t t/app-file-resolution.t t/routing/10-head-boundary.t t/integration-app-file-demo.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c lib/PAGI/App/File.pm && perl -Ilib -c t/app-file.t && perl -Ilib -c t/app-file-resolution.t'
git diff --check
```

Expected: all PASS, warning-free. Raw successful events contain `file` and no
`fh`; HEAD emits one terminal empty body event.

- [ ] **Step 6: Finish File POD and commit**

Replace the physical-symlink claim with the trusted-tree model. Document
404/403/405 division, Result interception, no production logging, server-owned
open, and the normal pathname race. Stage exactly these files and commit:

```bash
git add lib/PAGI/App/File.pm t/app-file.t t/app-file-resolution.t
git commit -m "refactor: serve files through shared engine"
```

Update Task 3's ledger row and review before Task 4.

---

### Task 4: Make Directory a Listing Layer Over File

**Files:**
- Modify: `lib/PAGI/App/Directory.pm`
- Modify: `t/34-directory-security.t`

**Interfaces:**
- Consumes: inherited `locate`, `serve`, root, index, and `allow_hidden` from
  File.
- Produces: Directory GET/HEAD listing only for a `directory` Result.
- Removes: `show_hidden`, `real_root`, `realpath`, and pre-delegation physical
  containment logic.

- [ ] **Step 1: Rewrite Directory contract tests first**

Change the current expected behavior:

```perl
is($client->get('/missing.txt')->status, 404,
    'missing directory candidate uses File not-found');
is($client->post('/listing')->status, 405,
    'unsupported method cannot render a listing');
is($client->post('/listing')->header('Allow'), 'GET, HEAD');
```

Add listing HEAD parity, hidden listing/direct retrieval with default false and
`allow_hidden => 1`, file/index ETag/range parity with File, and outward-symlink
file success. Retain all HTML escaping and URL encoding hostile-name tests.
Replace any test description claiming physical symlink confinement.

- [ ] **Step 2: Run RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/34-directory-security.t'
```

Expected: FAIL on missing 404, listing POST 405, `allow_hidden`, HEAD listing,
and outward symlink behavior.

- [ ] **Step 3: Replace Directory path resolution with File delegation**

Remove the Directory constructor unless it adds a listing-only option. In
`to_app`:

1. require explicit HTTP scope;
2. delegate unsupported methods to the parent File app before locating;
3. call inherited `locate` once for GET/HEAD;
4. call inherited `serve` for every non-directory result; and
5. for a directory, install `HeadBoundary`, call `_send_listing` with
   `$result->path`, and suppress listing-body bytes on HEAD.

The listing loop must use inherited `allow_hidden` for entries. An `opendir`
permission failure renders Pages forbidden; other unexpected I/O failures
propagate rather than becoming an ad hoc 500.

- [ ] **Step 4: Run GREEN and parity gates**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/34-directory-security.t t/app-file.t t/app-file-resolution.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c lib/PAGI/App/Directory.pm && perl -Ilib -c t/34-directory-security.t'
git diff --check
```

Expected: all PASS. GET and HEAD listing Content-Lengths agree; no HEAD listing
body bytes are emitted.

- [ ] **Step 5: Update POD and commit**

Document Directory as a File subclass/listing policy, `allow_hidden`, method
ownership, Pages outcomes, and trusted symlinks. Stage exactly two files:

```bash
git add lib/PAGI/App/Directory.pm t/34-directory-security.t
git commit -m "refactor: delegate directory serving to file engine"
```

Update Task 4's ledger row and review before Task 5.

---

### Task 5: Make Static an Eligibility Layer Over File

**Files:**
- Modify: `lib/PAGI/Middleware/Static.pm`
- Modify: `t/middleware/04-static.t`

**Interfaces:**
- Consumes: `PAGI::App::File->new`, `locate`, `serve`, and `allow_hidden`.
- Preserves: regex/coderef match/rewrite, local rewritten path, scope identity,
  non-HTTP/method bypass, `pass_through`, indexes, ranges, and default MIME.
- Removes: Static's duplicated path resolver, traversal stack, MIME table,
  ETag, range, stat, and file-event implementation.

- [ ] **Step 1: Add behavior and delegation tests**

Extend `t/middleware/04-static.t` with:

- hidden default 403 and `allow_hidden => 1` success;
- traversal/mixed-separator 403 even with `pass_through => 1`;
- missing and indexless directory pass-through versus owned 404;
- POST to a matching static path reaches the inner app unchanged;
- rewritten-path file success without mutating `$scope->{path}`;
- the same file through File and Static has equal Content-Type, Content-Length,
  ETag, 304, Range, Content-Range, and HEAD behavior; and
- raw successful Static body uses `file`, never `fh` or in-memory `body`.

Replace `$self->{file}` in one test instance with a local engine whose `locate`
dies with `simulated static probe failure`; assert the wrapper propagates that
exception and emits no response events.

Use a sentinel downstream response to prove each bypass/pass-through branch.

- [ ] **Step 2: Run RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/middleware/04-static.t'
```

Expected: FAIL on hidden policy, engine parity, and the new shared behavior.

- [ ] **Step 3: Construct one File engine in `_init`**

Keep only Static-owned configuration and build:

```perl
$self->{file} = PAGI::App::File->new(
    root          => $config->{root},
    index         => $config->{index} // ['index.html', 'index.htm'],
    handle_ranges => $config->{handle_ranges} // 1,
    allow_hidden  => $config->{allow_hidden} // 0,
);
```

Do not add a per-request File object. Remove dead duplicated MIME/range/path
methods after the wrapper no longer calls them.

- [ ] **Step 4: Implement the thin wrapper flow**

Preserve the current eligibility order: scope, method, matcher, rewrite. Then:

```perl
my $result = $self->{file}->locate($path);

if (($result->is_missing || $result->is_directory)
        && $self->{pass_through}) {
    return await Future->wrap($app->($scope, $receive, $send));
}

return await $self->{file}->serve($scope, $send, $result);
```

Do not pass forbidden results downstream. Do not replace `$scope->{path}` with
the rewritten local path. Use `Future->wrap` for inner-app and File completion
where either immediate or Future-backed completion is accepted.

- [ ] **Step 5: Run GREEN and cross-component gates**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/middleware/04-static.t t/app-file.t t/app-file-resolution.t t/34-directory-security.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c lib/PAGI/Middleware/Static.pm && perl -Ilib -c t/middleware/04-static.t'
git diff --check
```

Expected: all PASS. Confirm with a scoped source search that Static no longer
defines a private MIME table, ETag generator, traversal stack, or file response
sender.

- [ ] **Step 6: Update POD and commit**

Document `allow_hidden`, File delegation, exact pass-through boundaries,
trusted symlinks, and no local logging. Stage exactly two files:

```bash
git add lib/PAGI/Middleware/Static.pm t/middleware/04-static.t
git commit -m "refactor: delegate static middleware to file engine"
```

Update Task 5's ledger row and review before Task 6.

---

### Task 6: Make XSendfile Mapping Component-Aware and Header-Safe

**Files:**
- Modify: `lib/PAGI/Middleware/XSendfile.pm`
- Modify: `t/middleware/15-xsendfile.t`

**Interfaces:**
- Consumes: `PAGI::Utils::replace_path_prefix` from Task 1.
- Produces: deterministic longest-prefix hash mapping and safe decline.
- Preserves: direct no-mapping X-Sendfile/Lighttpd behavior, scalar mapping,
  filehandle `path` support, variation, and partial-response bypass.

- [ ] **Step 1: Write mapping-order and boundary RED tests**

Add raw event tests for:

```perl
mapping => {
    '/srv/files'         => '/internal/files',
    '/srv/files/private' => '/internal/private',
}
```

Assert `/srv/files/private/a.pdf` maps to `/internal/private/a.pdf`, exact root
maps cleanly, `/srv/files-old/a.pdf` does not match, and insertion/hash order
cannot change the winner. Use current-platform `File::Spec` paths for source
fixtures.

- [ ] **Step 2: Write unmatched and header-safety RED tests**

Assert a hash mapping with no match forwards the original buffered start and
`file` body event with no X-Accel header. Assert constructor croaks for mapping
destinations matching `[\x00-\x1f\x7f]`. Assert a file
suffix containing CR/LF causes safe decline rather than header emission. Keep
the recorder raw so it does not attempt to open the hostile fixture path.

- [ ] **Step 3: Run RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/middleware/15-xsendfile.t'
```

Expected: FAIL on textual false-prefix mapping, nondeterministic overlap,
unmatched raw-path header, and unsafe mapped header values.

- [ ] **Step 4: Normalize mapping records at construction**

Validate mapping shapes and configured replacement fragments. For a hash,
store records containing original key, normalized absolute source prefix,
replacement, normalized length, and deterministic lexical tie key. Sort by
descending normalized length then lexical key. Do not depend on `keys %hash`
request-time order.

- [ ] **Step 5: Replace `_map_path` and fix decline flow**

For each sorted hash record, call `replace_path_prefix`; return the first
defined mapping. For scalar mapping, slash-clean the prefix and whole source
path. Validate the final header value before appending it. When mapping or
header validation returns `undef`, flush the buffered start and forward the
original body event exactly once.

Keep offset/length responses entirely outside interception. Keep no-mapping
direct file paths for X-Sendfile and X-Lighttpd-Send-File.

- [ ] **Step 6: Run GREEN and compatibility gates**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/middleware/15-xsendfile.t t/utils-rooted-paths.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.16.3 && perl -Ilib -c lib/PAGI/Middleware/XSendfile.pm && perl -Ilib -c t/middleware/15-xsendfile.t'
git diff --check
```

Expected: all PASS. Verify every successful interception emits one start and
one terminal empty body; every decline preserves the original event sequence.

- [ ] **Step 7: Update POD and commit**

Document component boundaries, most-specific ordering, unmatched decline,
header safety, scalar/direct forms, and trusted configuration. Stage exactly:

```bash
git add lib/PAGI/Middleware/XSendfile.pm t/middleware/15-xsendfile.t
git commit -m "fix: make xsendfile mappings component aware"
```

Update Task 6's ledger row and review before Task 7.

---

### Task 7: Migrate Examples and Document the Security Contract

**Files:**
- Modify: `examples/10-chat-showcase/lib/ChatApp/HTTP.pm`
- Modify: `examples/10-chat-showcase/README.md`
- Modify: `examples/websocket-chat-v2/lib/ChatApp/HTTP.pm`
- Modify: `examples/websocket-chat-v2/README.md`
- Modify: `examples/app-01-file/README.md`
- Modify: `t/integration-chat-compose.t`
- Create: `t/integration-websocket-chat-v2.t`
- Modify: `lib/PAGI/Tools/Cookbook.pod`
- Modify: `lib/PAGI/Tools/Tutorial.pod`
- Modify: `lib/PAGI/Tools.pm`
- Modify: `README.md`
- Modify: `UPGRADING.md`
- Modify: `Changes`

**Interfaces:**
- Consumes: public `PAGI::App::File`, `path_from_root`, and XSendfile mapping
  behavior from Tasks 1–6.
- Produces: copy-paste examples with no manual traversal deletion or in-memory
  static file reads; complete migration and threat-model guidance.

- [ ] **Step 1: Add integration expectations before editing examples**

Extend `t/integration-chat-compose.t` to GET `/`, `/css/style.css`, and an
unknown non-API asset; assert index/CSS content, MIME type, and negotiated 404.
Also inspect `ChatApp/HTTP.pm` and assert it uses
`PAGI::App::File->app_path('public')->to_app` and contains no `_serve_static`,
manual MIME table, `File::Basename`, `File::Spec`, or file `open`.

Create `t/integration-websocket-chat-v2.t` as a separate test process/package
load. Exercise its root HTML and CSS through `PAGI::Test::Client`, then apply
the same source-shape assertions. Keeping it separate avoids collisions between
the two examples' intentionally identical `ChatApp::*` package names.

- [ ] **Step 2: Run example RED**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-chat-compose.t t/integration-websocket-chat-v2.t'
```

Expected: FAIL because both HTTP modules still contain manual static servers
and the new v2 integration contract is absent.

- [ ] **Step 3: Replace both manual static servers**

In each `ChatApp::HTTP`, remove `File::Spec`, `File::Basename`, the MIME table,
`_serve_static`, `_send_404`, and `_send_500`. Add:

```perl
use PAGI::App::File;

my $STATIC_APP = PAGI::App::File->app_path('public')->to_app;
```

Keep API dispatch first, then delegate every non-API HTTP request to
`$STATIC_APP`. Wrap completion with `Future->wrap` before awaiting if the local
handler accepts either immediate or Future-backed apps. Do not add a second
path helper or read static files into memory.

- [ ] **Step 4: Run example GREEN**

Run the two tests from Step 2. Expected: PASS with root HTML, CSS, API behavior,
and lifespan/logging behavior intact.

- [ ] **Step 5: Rewrite Cookbook and Tutorial examples**

Replace wildcard advice that says to invent canonical containment with a
complete raw-PAGI example:

```perl
use PAGI::Utils qw(path_from_root);
use PAGI::Pages;
use Future;

my $path = path_from_root('/var/www/files', $untrusted_path);
unless (defined $path) {
    my $response = PAGI::Pages->forbidden($scope);
    return await Future->wrap($response->respond($send));
}
```

Prefer mounting `PAGI::App::File` when no custom authorization or response
headers are needed. In the authenticated XSendfile download recipe, use
`path_from_root`, test authorization separately, avoid placing an unvalidated
request filename in Content-Disposition, and emit the validated lexical path
as the `file` event.

Document that symlinks extend administrator authority, roots should not be
attacker-writable, helper construction is lexical/no-I/O, and the server opens
the `file` event.

- [ ] **Step 6: Write the upgrade section and release notes**

Add a dedicated UPGRADING section with exact before/after examples and this
behavior table:

| Before | After |
|---|---|
| File NUL request -> 400 | common unsafe-path 403 |
| outward symlink rejected | trusted configured symlink served |
| Directory missing -> failed-realpath 403 | missing 404 |
| Directory POST listing -> 200 | 405, `Allow: GET, HEAD` |
| `show_hidden` listing-only option | `allow_hidden` serving/listing policy |
| Static hidden files allowed | hidden files forbidden by default |
| textual/hash-order XSendfile mapping | component-aware most-specific mapping |
| unmatched hash emits raw proxy path | original PAGI file event continues |

Update Changes, Tools/Cookbook/Tutorial cross-links, the affected example
READMEs, and the Tools front-page POD. Regenerate or edit `README.md` so it
matches the front-page POD; do not leave generated drift.

- [ ] **Step 7: Run documentation and integration gates**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-chat-compose.t t/integration-websocket-chat-v2.t t/integration-app-file-demo.t t/integration-app-file-examples.t'
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && podchecker lib/PAGI/Utils.pm lib/PAGI/App/File.pm lib/PAGI/App/Directory.pm lib/PAGI/Middleware/Static.pm lib/PAGI/Middleware/XSendfile.pm lib/PAGI/Tools/Cookbook.pod lib/PAGI/Tools/Tutorial.pod lib/PAGI/Tools.pm'
rg -n 'show_hidden|symlink escape detection|prevents symlink escape|\$path\s*=~\s*s/\\\.\\\.' lib examples README.md
rg -n 'show_hidden|symlink escape' UPGRADING.md Changes
git diff --check
```

Expected: tests and POD PASS. The scoped search has no live obsolete option,
physical-confinement claim, or first-party manual dot deletion. Matches in the
second search are required migration history and must be clearly labelled as
Before/changed behavior rather than a current recommendation.

- [ ] **Step 8: Compatibility checks and commit**

Compile changed ordinary Perl modules/tests under Perl 5.16.3. Then stage only
the files listed by Task 7 and commit:

```bash
git add examples/10-chat-showcase/lib/ChatApp/HTTP.pm examples/10-chat-showcase/README.md examples/websocket-chat-v2/lib/ChatApp/HTTP.pm examples/websocket-chat-v2/README.md examples/app-01-file/README.md t/integration-chat-compose.t t/integration-websocket-chat-v2.t lib/PAGI/Tools/Cookbook.pod lib/PAGI/Tools/Tutorial.pod lib/PAGI/Tools.pm README.md UPGRADING.md Changes
git commit -m "docs: migrate rooted file serving guidance"
```

Update Task 7's ledger row and review before Task 8.

---

### Task 8: Final Contract Audit and Release Gates

**Files:**
- Review: every file changed by Tasks 1–7
- Modify only if a concrete audit/test defect is found: the owning production,
  test, example, or documentation file, with a recorded focused fix commit.

**Interfaces:**
- Consumes: the complete approved design and Tasks 1–7.
- Produces: requirement-to-evidence audit, one final reviewed HEAD, one full
  suite result, and a build/archive inspection.

- [ ] **Step 1: Build the requirement-to-evidence audit**

In the Task 8 report, map every design section 4–12 requirement to an exact
test name/POD section. Explicitly account for:

- no-I/O utilities;
- dot/backslash/NUL/volume/directory-intent grammar;
- Result kinds and request isolation;
- index order and errno classification;
- positive outward symlink serving;
- metadata reuse and `file`, never application-opened `fh`;
- Pages 403/404/405 and propagated errors;
- File/Directory/Static HEAD and method behavior;
- Static pass-through boundaries;
- XSendfile boundary/order/header-safe decline;
- chat asset integration; and
- upgrade/threat-model documentation.

If evidence is missing, write a focused failing test first, record RED, make the
smallest contract-preserving fix, run GREEN, review it, commit it, and update
the ledger. Do not add speculative behavior.

- [ ] **Step 2: Run the aggregate focused gate**

Run:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/utils-rooted-paths.t t/app-file-resolution.t t/app-file.t t/34-directory-security.t t/middleware/04-static.t t/middleware/15-xsendfile.t t/integration-chat-compose.t t/integration-websocket-chat-v2.t t/integration-app-file-demo.t t/integration-app-file-examples.t'
```

Expected: PASS, warning-free except intentional captured diagnostics. Record
actual file/test counts and elapsed time.

- [ ] **Step 3: Run static, compatibility, and POD gates**

Run `git diff --check` from starting HEAD to final HEAD. Run Perl 5.16.3 syntax
checks for every changed `.pm` and ordinary `.t` file. Run `podchecker` for
every changed POD-bearing file. Run scoped searches proving:

```bash
rg -n 'Cwd::realpath|\brealpath\b|show_hidden|symlink escape detection|prevents symlink escape' lib/PAGI/App/File.pm lib/PAGI/App/Directory.pm lib/PAGI/Middleware/Static.pm
rg -n '_serve_static|s/\\\.\\\.' examples/10-chat-showcase examples/websocket-chat-v2
rg -n 'sub (_resolve_path|_is_safe_path|_resolve_dots|_generate_etag|_get_mime_type)' lib/PAGI/Middleware/Static.pm
```

Expected: no live matches. Historical Before examples in UPGRADING and design
documents are outside these live-source searches.

- [ ] **Step 4: Obtain final independent review**

Review the complete starting-HEAD-to-HEAD diff against the approved design,
including security, concurrent request isolation, response event ownership,
HEAD, and copy-paste docs. Resolve every Critical or Important finding before
the distribution suite. Record Minor findings and either fix them with focused
TDD or explicitly dispose of them in the audit report.

- [ ] **Step 5: Run the one final distribution suite**

At the reviewed HEAD, run exactly once:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t'
```

Expected: PASS. If sandboxed localhost binding alone fails, rerun the affected
network test and then the final suite with approved host access; record both
outputs. If a real defect changes HEAD, record RED/fix/review and run one fresh
final suite at the corrected HEAD.

- [ ] **Step 6: Build and inspect the distribution without retesting**

Run `dzil build` but not `dzil test`. Inspect the generated archive and metadata
to confirm it contains `PAGI::App::File::Result`, updated POD, the new tests as
appropriate for the distribution, and no undeclared dependency. Confirm the
source worktree has no unexpected generated diff.

- [ ] **Step 7: Close the ledger and report the branch**

Record final SHA, exact task commit ranges, focused/full-suite/build results,
review outcome, and work-map reconfirmation. Verify the branch is
`feat/rooted-file-serving`, the tracked worktree is clean, unrelated source
checkout files remain untouched, and no push occurred.

Do not merge, push, tag, or deploy without a new explicit user request.
