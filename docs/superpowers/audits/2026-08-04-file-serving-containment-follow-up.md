# File-Serving Containment Follow-up

**Date:** 2026-08-04
**Status:** Needs security reproduction and a separate remediation design
**Scope:** `PAGI::App::File` and `PAGI::Middleware::Static`; independent of
declarative routing

## Context

The declarative-routing review added a warning that wildcard captures are
untrusted decoded input and are not safe filesystem paths. Before pointing to
the shipped file-serving components as a security guarantee, their containment
implementations were inspected.

No routing implementation work should absorb these findings. They need focused
reproduction tests, compatibility analysis, and remediation in a separate
security change.

## Finding 1: `PAGI::App::File` path-boundary comparison

`PAGI::App::File` resolves a candidate with `Cwd::realpath`, then currently
checks containment with:

```perl
index($real_path, $root) == 0
```

A string-prefix test does not establish a path-component boundary. For example,
`/srv/files-private/item` has the prefix `/srv/files` without being beneath the
`/srv/files` directory. A reproduction should cover a symlink beneath the root
whose resolved target has such a sibling-prefix path.

The remediation design should compare either exact root equality or a root
prefix followed by the platform separator, after canonical resolution.

## Finding 2: `PAGI::Middleware::Static` symlink containment

`PAGI::Middleware::Static` lexically resolves dot components and verifies that
the resulting path string remains under its configured root. The inspected
path does not resolve the final filesystem target before the file is served.

A reproduction should determine whether a symlink located beneath the static
root can reference a readable file outside that root. The remediation design
must state whether symlinks are forbidden, allowed only when their resolved
targets remain contained, or governed by an explicit option.

## Required follow-up

- Add isolated regression tests using temporary roots and outside sibling
  directories.
- Cover files, directories, symlinks, nonexistent targets, and platform path
  separators where supported.
- Define compatibility behavior for deployments that intentionally serve
  through symlinks.
- Document the containment guarantee precisely in both file-serving modules.
- Do not describe either module as a security boundary until the reproduction
  and remediation work is complete.
