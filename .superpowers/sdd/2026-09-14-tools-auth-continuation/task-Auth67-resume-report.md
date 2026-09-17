# Auth6/7 resume report

Branch: `feature/universal-connection-tools`

Starting checkpoint: `a6e18efbc104118969ed5e6c16410f985d2df09c`

## Auth6: explicit cookie login policy

- RED command: `PERL_FUTURE_NO_XS=1 /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-auth-cookie-login.t'`
- RED evidence: `Files=1, Tests=21`; 1 failed load assertion and 20 skipped journey assertions because `examples/auth-cookie-login/app.pl` did not exist.
- GREEN command: `PERL_FUTURE_NO_XS=1 /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-auth-cookie-login.t t/middleware/10-session-auth.t'`
- GREEN evidence: `Files=2, Tests=40`, all successful. The new journey contains 22 assertions; the middleware file contains 18 top-level subtests.
- Commit: `323298d Add cookie login policy example`
- Documentation correction: `f75585d Correct cookie login example run command`
  supplies `--lib lib` and states the Perl 5.40 minimum after review.

## Auth7: outcome-only apples route

- RED command: `PERL_FUTURE_NO_XS=1 /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-starlette-apples.t'`
- RED evidence: `Files=1, Tests=6`; top-level tests 5 and 6 failed because the named route was absent and `/apples/auth-required` returned the child Router's 404 instead of the challenge.
- GREEN command: `PERL_FUTURE_NO_XS=1 /bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-starlette-apples.t t/auth/03-outcomes.t'`
- GREEN evidence: `Files=2, Tests=14`, all successful. The apples journey contains 85 assertions; the outcome file contains 8 top-level subtests.
- Python block SHA256: `5841982d7452eaaba77a23fc9063fbe6fef53b8ea291371e7ed179789adb1835`.
- Perl source synchronization: `yes`; the README Perl block equals `app.pl` after removal of the executable shebang.
- Commit: `3dc1bc8 Demonstrate auth outcomes in apples`

## Scope and concerns

- `git diff --check` passed before both commits.
- No auth parser, provider, runtime, or middleware implementation changed. The existing `PAGI::Utils::Middleware` namespace in `AppleApp::Middleware` remains unchanged.
- No full suite was run; Auth8 owns that gate.
- The pre-existing dirty tracking document and untracked notes were not staged or modified by this task.

## Review fix round 1

- Added the established pre-load Perl version gate to
  `t/integration-auth-cookie-login.t`, so supported Perl 5.18 through 5.38 skip
  the Perl 5.40 example before parsing it.
- Corrected the guarded journey's fallback skip count from 20 to 21.
- The report is ignored by `.superpowers/sdd/.gitignore`, so it is retained as
  local task evidence and is not part of the review-fix commit.
