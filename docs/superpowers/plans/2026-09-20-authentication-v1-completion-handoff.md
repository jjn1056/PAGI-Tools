# Authentication v1 completion handoff

Date: 2026-09-21

Authentication v1 is implemented and locally exercised in PAGI-Tools. It has
not been merged, released, deployed, or pushed. The single full-suite gate has
one known baseline failure in a sibling-server integration test; this handoff
does not treat that result as a clean suite pass or a new Server wire-level gate.

## Work map and authority

| Repository | Ticket | Branch | Base and current commit | Owned boundary | Push target |
| --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Authentication v1; no external ticket | `feature/universal-connection-tools` | recorded implementation base `f731ea9ae7580063e836540a1386ce7f84ce1ce7`; Task 8 starting/current HEAD `980a1d79c993d93eb8834138c9369e97022359ea` | local library, tests, examples, and public docs | none |

Final Task 8 commit is pending the controller's scoped staging and commit. No
commit hash for that work exists at this handoff. PAGI and PAGI-Server were
read-only reference repositories. The canonical
[Auth v1 spec](../specs/2026-09-17-authentication-backends-and-context-design.md)
records the settled contract and earlier design discussion; this handoff and
the [PAGI::Auth reference](../../../lib/PAGI/Auth.pm) identify what is
implemented and tested. Earlier source-only statements in the spec retain their
historical review context.

## Delivered behavior

`PAGI::Auth` optionally exports `auth`, `auth_result`, `unauth_result`, and
`www_authenticate`, with function, class, and instance forms. The completed
Result holds a user, Credentials containing live granted scopes, and an
optional public Failure. `pagi.auth` contains that Result directly. Missing
context is an error; a custom authenticator can install a complete Result in a
cloned scope. No `authenticated` grant is inserted automatically. User objects
and supplied scope arrays retain ordinary Perl reference semantics.

Generic `PAGI::Middleware::Authentication` accepts a coderef or object backend
that receives the Request, returns one completed Result directly or through a
Future, and continues downstream on HTTP, WebSocket, and SSE. It passes other
scope types through. Backend parsing and verification, explicit 400/401/403
responses, permissions, and challenge headers remain application decisions.
Exceptions and failed Futures propagate. The former Auth Challenge/Outcomes
objects and Basic/Bearer middleware were removed without compatibility aliases.
No OAuth token acquisition, redirect flow, refresh, discovery, browser feature,
or new required runtime dependency was added.

The [Notes example](../../../examples/auth-notes/README.md) covers a small
opaque-token API. The [JWT sandbox](../../../examples/auth-jwt-sandbox/README.md)
shows inline and group checks; `Crypt::JWT` is optional and example-local. The
[extension examples](../../../examples/auth-extensions/README.md) cover custom
users/factories, Basic backend objects, context placement, response forms,
protocol admission, and challenge headers. The Auth POD includes an executable
group-protection recipe; its extracted test verifies two routes, public traffic,
guest/accepted/rejected requests, startup/shutdown, and the same route nodes
after removing the protection wrapper for comparison.

## Validation

| Gate | Actual result |
| --- | --- |
| `perlbrew exec --with perl-5.40.0@default prove -lr t/auth` | PASS, 9 files / 182 tests before the final cookbook readability refinement |
| `perlbrew exec --with perl-5.40.0@default prove -lv t/00-pod/cookbook-examples.t t/integration-auth-jwt-sandbox.t t/integration-auth-notes.t t/integration-starlette-apples.t t/integration-auth-cookie-login.t` | PASS, 5 files / 99 top-level tests |
| `perlbrew exec --with perl-5.40.0@default podchecker` on the seven changed Auth/Middleware `.pm` files | PASS, each reported `pod syntax OK` |
| `perlbrew exec --with perl-5.20.0 prove -lv t/integration-auth-jwt-sandbox.t t/auth/11-extension-examples.t t/auth/12-cookbook.t` | Exit 0, all three example tests skipped because they require Perl 5.40 (`NOTESTS`) |
| `perlbrew exec --with perl-5.40.0@default prove -I../PAGI-Server/lib -lr t` | FAIL, 238 files / 2839 top-level tests; only `t/integration/protocol-refusal-stream-disconnect.t` failed 7/13 subtests (1-3, 7-8, 11-12) |
| After that full run: `perlbrew exec --with perl-5.40.0@default prove -lv t/auth/12-cookbook.t`; `podchecker lib/PAGI/Auth.pm`; `git diff --check` | PASS, 14 cookbook assertions; POD syntax OK; no whitespace errors |

The full-suite log is
[`task-8-full-suite.log`](../../../.superpowers/sdd/2026-09-20-authentication-v1-implementation/task-8-full-suite.log).
The failing integration file invokes the read-only sibling PAGI-Server main,
which rejects `ws_close_timeout` as an unrecognized option. This is the same
failure observed before Auth v1 implementation. Existing Future sequence
warnings remain in the log; `t/request/multipart-stream-e2e.t` was skipped
because `RELEASE_TESTING=1` was not set. Optional HTTP/2 dependency skips were
part of the known baseline, but the quiet full-suite summary does not count
individual skipped subtests. The declared Perl 5.018 library floor was not run
because that interpreter is unavailable locally. The Perl 5.20 run verifies
only that 5.40 example tests skip before loading incompatible dependencies.
No new Server wire-level joint probe was run.

The full suite ran once before the final cookbook-only POD/test readability
refinement; it was not repeated. The affected extracted cookbook test and POD
check passed after that change. The Auth-focused gate's 182-test count refers
to the earlier 13-assertion cookbook; the final cookbook has 14 assertions.

Task 8's detailed file ownership and red/green evidence are in the
[`task-8-report.md`](../../../.superpowers/sdd/2026-09-20-authentication-v1-implementation/task-8-report.md).
