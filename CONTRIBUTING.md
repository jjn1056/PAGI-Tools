# Contributing to PAGI

Thanks for your interest in contributing to PAGI!

## Quick Start

1. Fork the repository
2. Make your changes
3. Run tests (see below)
4. Submit a pull request

## What to Contribute

**Bug fixes and documentation corrections** - Submit a PR directly. For bugs,
please include a failing test case demonstrating the issue.

**New features, API changes, or significant refactors** - Open an issue first
to discuss the approach. This ensures your time isn't wasted on something that
might not fit the project's direction.

## Code Style

Follow the existing code style. Key conventions:

- 4-space indentation (no tabs)
- Opening braces on same line
- Descriptive variable names
- Keep methods focused and reasonably sized

When in doubt, match what you see in the surrounding code.

Library code and tests start with `use v5.24;` and `use warnings;` (the 5.24
version bundle turns on strict but not warnings), and use no signatures,
which are experimental before 5.36. Examples in POD and in `examples/` use
`use v5.40;` and signatures, and POD examples define classes as
`package Name { ... }`.

## Bytes, characters and `use v5.24`

PAGI hands an application bytes: `raw_path`, query strings, header values and
request bodies are bytes, not characters. `use v5.24;` (like any `use v5.12;`
or later) turns on the `unicode_strings` feature, and with it Perl applies
Unicode rules to bytes 128-255 in a string that is not marked as UTF-8:

- `\s` matches the bytes `\x85` and `\xA0`;
- `\w` matches bytes such as `\xC3`;
- `lc`, `uc` and `/i` treat `\xC0`-`\xFF` as Latin-1 letters, and `/i` even
  lets the single byte `\xDF` (ß) match the ASCII pattern `ss`.

So a regex that was right on bytes can silently corrupt them. "à" is the two
bytes `\xC3\xA0` in UTF-8, and `s/\s+$//` strips the `\xA0`, cutting the
character in half.

The rule: in code that handles bytes, write the regex for what it means.

- HTTP whitespace is space and tab: write `[ \t]`, not `\s`.
- A token or a name is ASCII: write `[A-Za-z0-9_]` (or use `/a`), not `\w`.
- A case-insensitive match against an ASCII pattern, such as a header name:
  use `/iaa`. Plain `/i`, and even `/ia`, let `\xDF` match `ss`; the doubled
  `a` never lets a non-ASCII byte match an ASCII character.
- To lowercase bytes, use `tr/A-Z/a-z/`, which changes ASCII letters only;
  `lc` also changes `\xC0`-`\xDE`.

Don't turn the feature off with `no feature 'unicode_strings'`: fix the regex.
Every module that takes or returns bytes adds cases to `t/bytes.t`, which
sends `\x85`, `\xA0`, `\xC3\xA0` and `\xC9` through its public methods and
checks they come out unchanged.

## Running Tests

The test suite is self-contained — no external servers or cross-repository
paths are needed. Just:

```bash
prove -lr t/                     # Run the full suite
prove -l t/runner.t              # Run a single file
```

No extra `PERL5LIB` or environment variables are required. The suite is
fully self-contained: every Runner↔server assertion runs against the
bundled `PAGITest::FakeServer` fixture in `t/lib/`. There is no dependency
on `PAGI::Server` at test time — real-server integration tests live in the
`PAGI-Server` distribution.

## The test client is versioned API

`PAGI::Test::Client` and its SSE and WebSocket companions are what
applications' test suites are written against, so a change to what they
report (when a stream counts as closed, a disconnect reason or detail, an
event's shape) gets an entry in `UPGRADING.md`, as any public behaviour
change does. Their outcomes follow PAGI::Server's; `t/test/terminal-parity.t`
pins them.

## AI-Assisted Contributions

AI tools are welcome in your workflow. However, you're responsible for
understanding, testing, and standing behind any code you submit.

## Expectations

This is a volunteer project maintained in my spare time. I cannot commit to
timelines for reviewing PRs or responding to issues.

If your organization needs priority support, expedited PR review, or custom
development, I'm available for contract work. Contact jjnapiork@cpan.org to
discuss.

## Questions?

Open an issue on GitHub or reach out to the maintainer.
