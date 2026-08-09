# Inline Constraint Providers Design

**Date:** 2026-08-09

**Status:** Approved design; awaiting written-spec review

## 1. Decision

Add an inline constraint-provider form to declarative routing paths:

```perl
use Types::Standard qw(Int);

route('/{person_id:&Int}' => \&show_person);
```

An inline constraint source that consists entirely of `&` followed by a
capitalized package-function name is a provider reference rather than a Perl
regular expression. PAGI resolves the function in the route declaration
package, invokes it with no arguments while constructing the route
description, normalizes its return value through the existing constraint
contract, and stores the resulting checker with the immutable path pattern.

The provider may return any constraint shape already accepted by PAGI:

1. a `Regexp`;
2. a predicate coderef; or
3. a blessed object implementing `check`, with optional `get_message`.

The provider itself never runs during request matching or reverse routing.
The returned checker does. Constraints remain synchronous validation and
never coerce captured or reverse-routing values.

The design does not depend on `Type::Registry`. It does not inspect Perl
signatures, use method dispatch, evaluate strings as Perl, or load a package
named in a route.

Type::Tiny works because an imported type such as `Int` is an ordinary
package function returning a `check`-compatible object.

This work also modernizes `examples/15-large-application` to require Perl
5.40 and use signatures. Its `routing` entry points remain class methods:

```perl
sub routing($class) { ... }
```

The example modernization does not add a new component base class, export
route arrays, cache one Router globally, or change the distribution's Perl
5.18 minimum.

## 2. Motivation

The current canonical constraint form is explicit and supports Perl-native
regexes, predicates, and Type::Tiny-compatible objects:

```perl
route('/{person_id}' => \&show_person,
    constraints => { person_id => Int },
);
```

That form remains valuable for dynamic or unusually complex constraints, but
it separates a simple reusable constraint from the path parameter it
describes. Repeating the same parameter on a route and a mount makes the
visual cost more obvious:

```perl
route('/{person_id}' => \&show_person,
    constraints => { person_id => Int },
);

mount('/{person_id}/blog',
    router      => MyApp::Person::Blogs->routing,
    namespace   => 'blog',
    constraints => { person_id => Int },
);
```

The inline provider keeps the reusable semantic constraint beside the
parameter:

```perl
route('/{person_id:&Int}' => \&show_person);

mount('/{person_id:&Int}/blog',
    router    => MyApp::Person::Blogs->routing,
    namespace => 'blog',
);
```

The leading `&` is an explicit signal that constructing the pattern will call
a function. Requiring an uppercase provider name follows the convention used
by exported Type::Tiny types and reduces accidental overlap with ordinary
Perl handler and helper names.

This is deliberately validation rather than Starlette-style conversion. A
Type::Tiny `Int` checker may accept a captured scalar, but the handler still
receives the original decoded scalar. Reverse routing validates the supplied
scalar and then percent-encodes that same value.

## 3. Goals

- Put common named constraints next to their path parameters.
- Reuse the three constraint shapes PAGI already accepts.
- Work naturally with `Types::Standard`, application type libraries, and
  small package-local provider functions.
- Keep Type::Tiny and `Type::Registry` out of the core dependency and lookup
  contract.
- Make provider recognition deterministic and distinct from almost all
  existing inline regexes.
- Resolve and execute providers at routing-description construction time.
- Preserve resolved provider constraints through matching, Router mounts,
  composed reverse routing, `path_for`, and `url_for`.
- Keep constraints synchronous and non-coercing.
- Fail during construction for missing providers, provider exceptions,
  Future results, and invalid result values.
- Modernize the diagnostic large application to Perl 5.40 and signatures so
  its comparison with modern Starlette code is not dominated by legacy Perl
  syntax.

## 4. Non-goals

- Add a global or Router-local type registry.
- Integrate directly with `Type::Registry`.
- Add Starlette-style converters that replace captured strings with integers,
  UUID objects, dates, or other values.
- Add builtin symbolic constraints such as `int`, `uuid`, or `path`.
- Accept arbitrary expressions, arguments, method calls, variables, or object
  references inside a path string.
- Dynamically load a package named by a provider reference.
- Invoke `AUTOLOAD` or inherited methods while resolving a provider.
- Pass a Context, path value, class invocant, or request state to a provider.
- Make providers asynchronous.
- Replace explicit `constraints => {...}`.
- Add inline providers to the explicit constraints hash; a scalar such as
  `constraints => { id => '&Int' }` remains invalid.
- Add a route-component base class or role.
- Replace `MyApp::Root->routing` and child `routing` methods with exported
  arrays, zero-argument package functions, or process-global cached Routers.
- Raise PAGI::Tools' distribution-wide minimum Perl version.

## 5. Provider-reference grammar

### 5.1 Complete recognition

Provider syntax is recognized only inside the existing inline parameter form:

```text
{parameter:constraint-source}
```

The complete `constraint-source` must match this grammar:

```text
provider-reference = "&" [ package-prefix "::" ] provider-name
package-prefix     = package-component *( "::" package-component )
package-component  = ( ALPHA / "_" ) *( ALPHA / DIGIT / "_" )
provider-name      = UPPER *( ALPHA / DIGIT / "_" )
```

`ALPHA`, `UPPER`, and `DIGIT` mean ASCII characters. The terminal provider
function must begin with `A` through `Z`. Package components use ordinary
ASCII Perl package-identifier syntax and need not begin uppercase.

These are provider references:

```perl
'/{id:&Int}'
'/{id:&PersonId}'
'/{id:&MyApp::Types::PersonId}'
```

These remain inline regular expressions because the complete source does not
match the provider grammar:

```perl
'/{value:&lower}'
'/{value:&[A-Z]+}'
'/{value:&Foo|Bar}'
'/{value:&Foo.*}'
'/{value:&Foo::lower}'
```

Once a source has provider-reference syntax, it is always a provider
reference. Failure to resolve the named function is a construction error; it
must not fall back to a regex that matches the provider's spelling.

### 5.2 Literal leading ampersands

In a Perl regular expression, an unescaped `&` is an ordinary literal.
Therefore the exact regex source `&Int` collides with the new provider
spelling. Authors who need that exact regex can spell it without provider
syntax:

```perl
route('/{value:[&]Int}' => \&handler);
route('/{value:\&Int}'  => \&handler);
```

`[&]Int` is the canonical documented escape because it is visibly regex
syntax and does not depend on Perl string escape behavior. Both patterns
match the decoded scalar `&Int`.

This routing API has not been released. Reserving the narrow
`&CapitalizedName` spelling requires documentation and tests but no
compatibility alias or deprecation period.

### 5.3 Existing tokenization remains

The existing inline-constraint scanner still determines the matching closing
brace, including escaped characters, character classes, quantifier braces,
and ordinary regex comments. Provider recognition happens only after that
scanner has extracted the complete constraint source.

All non-provider sources continue through the existing anchored inline-regex
compiler. Provider recognition does not reinterpret `{name}`, legacy `:name`,
or wildcard `*name` tokens.

## 6. Where provider syntax applies

Provider syntax is part of the shared path grammar. It works anywhere the
existing `{name:pattern}` syntax works:

- normal HTTP routes;
- raw HTTP routes;
- WebSocket routes;
- SSE routes;
- inline mounts;
- known Router mounts; and
- opaque application mounts.

This does not change which constructor options each route kind accepts.
WebSocket and SSE routes continue to reject the explicit `constraints`
option, but their paths may use either existing inline regexes or inline
providers because those are properties of the shared path pattern.

## 7. Declaration package and function lookup

### 7.1 Declaration package

An unqualified provider resolves relative to the package that directly calls
the public routing constructor:

```perl
package MyApp::Person;

use Types::Standard qw(Int);
use PAGI::Routing qw(route);

sub routing($class) {
    return router(
        routes => [
            route('/{person_id:&Int}' => \&show_person),
        ],
    );
}
```

Here `&Int` resolves to the `Int` function installed in `MyApp::Person`.
Calling `MyApp::Child::Person->routing` does not rebind it to
`MyApp::Child::Person`. The declaration remains owned by the package whose
code contains the `route(...)` call.

The `route`, `websocket`, `sse`, and `mount` functions capture their direct
caller's package and carry that construction-only metadata into the Route,
Mount, and Pattern constructors. A direct call to an object constructor uses
its own direct caller as the declaration package.

The private constructor seam is explicit: the public factory functions call
`PAGI::Routing::Route->_new_from($package, $kind, @args)` or
`PAGI::Routing::Mount->_new_from($package, @args)`. Direct `new` calls capture
their own caller and delegate to the same seam. A direct Pattern construction
defaults to its direct caller and may pass
`declaration_package => $package` for focused tests. Resolver composition
uses already-normalized checker records and does not need a declaration
package.

Once a descriptor is built, passing it through another package, Router, or
mount never changes its declaration package or re-resolves its providers.

A wrapper around a public constructor becomes the declaration package because
it is the direct caller:

```perl
package MyApp::RoutingDSL;

sub person_route($path, $handler) {
    return route($path => $handler);
}
```

An unqualified provider embedded in `$path` resolves in
`MyApp::RoutingDSL`, not in the package that called `person_route`. A wrapper
should import its providers itself or require callers to use fully qualified
provider names. PAGI does not walk the call stack looking for a preferable
namespace.

### 7.2 Exact subroutine resolution

An unqualified reference such as `&Int` looks for the exact `Int` CODE slot in
the declaration package. An imported function therefore works because it is
installed in that package's symbol table.

A qualified reference such as `&MyApp::Types::PersonId` looks for exactly that
CODE slot. The package must already be loaded by normal Perl code.

Resolution must not:

- search `@ISA`;
- perform method dispatch;
- call `can` in a way that admits inherited methods;
- invoke `AUTOLOAD`;
- `require` or otherwise load the named package;
- consult `Type::Registry`; or
- evaluate the provider spelling as Perl source.

These restrictions keep provider meaning stable under subclassing and make
the `&` notation mean a package function rather than a method.

Roles and base classes can declare provider-backed paths, but the provider
belongs to the package containing that declaration. A reusable declaration
that needs a specific external provider should use its fully qualified name.
A subclass-dependent constraint remains expressible through the existing
explicit constraint form constructed from `$class`; it is not encoded into
the inline provider string.

## 8. Provider execution and accepted results

After resolving the CODE slot, construction calls the provider directly with
an empty argument list and no invocant:

```perl
my $value = $provider->();
```

The provider runs once for each declared source Pattern constructed from the
route or mount declaration. It does not run while the resolver constructs an
effective composed Pattern. No process-global cache is promised: if
application code calls a `routing` method twice and constructs two route
descriptions, the provider runs once for each source description.

The result is normalized through the same rules as an explicit constraint:

```text
Regexp                 anchored full-value regex checker
CODE                   synchronous unary predicate checker
blessed object->check  synchronous check-object checker
anything else          construction error
```

The distinction between provider and predicate is structural. PAGI invokes
the named provider with no arguments during source construction. If that call
returns a coderef, PAGI stores the returned coderef and later invokes it with
one path value as the predicate.

A check object may also implement `get_message`, which retains its existing
role in reverse-routing validation errors. Regexes are anchored with `\A` and
`\z`. Returned predicates receive only the decoded or reverse-supplied scalar.

A provider may throw. The exception fails construction with context naming
the provider, parameter, and declaration package. A provider returning a
Future fails construction even if that Future would eventually resolve to an
accepted constraint. Provider construction and all later constraint checks
are synchronous.

Provider functions should be deterministic and free of request-specific side
effects. PAGI does not attempt to prove purity. Executing a provider during
construction is comparable to executing any other application factory while
building immutable routing descriptions.

## 9. Matching, explicit constraints, and validation order

The provider's normalized checker occupies the same position currently held
by an inline regex checker. Request matching applies it to the complete
decoded parameter value.

An explicit constraint may still target the same parameter:

```perl
route('/{person_id:&Int}' => \&show_person,
    constraints => {
        person_id => sub($value) { $value > 0 },
    },
);
```

Both constraints must pass. The inline provider checker runs first, followed
by the explicit checker, preserving the existing inline-regex-plus-explicit
constraint order.

For request matching:

- a false checker result makes that declaration a non-match;
- checker exceptions propagate;
- a Future checker result is rejected; and
- the accepted captured value remains the original decoded scalar.

For reverse routing:

- missing or extra parameters retain the existing errors;
- a false checker result croaks with the route and parameter context;
- a check object's `get_message` may add detail;
- checker exceptions propagate; and
- the accepted scalar is percent-encoded without conversion.

Provider functions themselves are not called in either request-time path.

## 10. Immutability and composed reverse routing

Resolved provider results are part of the immutable Pattern description. The
resolved checker identity must survive:

- Route or Mount construction;
- Router construction;
- `to_app` compilation;
- nested inline mounts;
- known Router mounts;
- more than one placement of the same Router; and
- effective-pattern construction for `path_for` and `url_for`.

The resolver must not rebuild a provider-backed effective pattern by parsing
the concatenated path string under one caller package. Different mount and
leaf segments may have been declared in different packages, and reparsing
would call providers again or resolve them in the wrong namespace.

Instead, each source Pattern exposes private defensive copies of its
already-normalized per-parameter checker-record arrays. Router composition
merges those records by parameter name and supplies them through a private
pre-normalized constructor channel when it builds the effective reverse
Pattern. When that channel is present, tokenization recognizes the inline
source text but does not compile its regex or resolve and call its provider a
second time. Inline provider checkers, inline regex checkers, and explicit
constraints all participate. Existing duplicate path-parameter rejection
ensures one composed path cannot contribute two independently named checker
sets for the same parameter.

This requirement also closes a consistency gap for existing inline regexes:
an inline regex used during dispatch must remain enforced when rendering the
same route through `path_for` or `url_for`. Provider work must not introduce a
second representation that behaves differently from regex-backed paths.

Accessor behavior does not change. Public `constraints` accessors continue to
describe the explicit `constraints => {...}` option rather than synthesizing
inline checker values. The original path string remains available for normal
inspection; normalized checker records are private immutable composition
data.

## 11. Errors

All provider-definition errors occur during Route, Mount, Pattern, or Router
description construction, before the application handles a request.

Diagnostics must identify the parameter and provider spelling. When relevant,
they also identify the declaration package. Required error categories are:

```text
inline constraint provider '&Missing' for parameter 'id' is not defined in package 'MyApp::Routes'
inline constraint provider '&Bad' for parameter 'id' failed in package 'MyApp::Routes': ...
inline constraint provider '&Async' for parameter 'id' returned a Future
inline constraint provider '&Bad' for parameter 'id' must return a Regexp, coderef, or check object
```

Exact punctuation may follow existing `croak` style, but tests assert the
provider spelling, parameter name, package where applicable, and the stable
reason. An exception thrown by a provider retains its original detail after
the contextual prefix.

A syntactically valid provider reference that cannot be resolved never falls
back to regex compilation.

## 12. Type::Tiny without a registry dependency

Type::Tiny is supported through the existing check-object seam:

```perl
package MyApp::Person;

use v5.40;
use Types::Standard qw(Int);

sub show_person($c) {
    my $person_id = $c->path_param('person_id');
    # $person_id is still the original string.
    ...
}

sub routing($class) {
    return router(
        routes => [
            route('/{person_id:&Int}' => \&show_person,
                name => 'show',
            ),
        ],
    );
}
```

`Types::Standard` installs `Int` into `MyApp::Person`. Calling it without
arguments returns a Type::Tiny object implementing `check` and
`get_message`. PAGI needs no knowledge of the type's registry or library.

The type's own semantics control acceptance. In particular,
`Types::Standard::Int` accepts an optional leading minus sign; it is not an
alias for the regex `\d+`. It still performs validation only. PAGI does not
use Type::Tiny coercions or convert a captured value into a numeric scalar.

Applications that need a refined or parameterized type should export a
capitalized, zero-argument provider with a semantic name such as `PersonId`.
The route grammar does not attempt to embed the Type::Tiny expression DSL.

The PAGI::Tools runtime dependency list does not add Type::Tiny. The large
application integration test does exercise `Types::Standard`, so the
`Type-Tiny` distribution is added only to test prerequisites and the example
README names it as an example dependency.

## 13. Large-application modernization

Every Perl source under `examples/15-large-application` changes from the
legacy preamble and manual argument unpacking:

```perl
use strict;
use warnings;

sub show_person {
    my ($c) = @_;
    ...
}
```

to Perl 5.40 and signatures:

```perl
use v5.40;

sub show_person($c) {
    ...
}
```

This includes `app.pl`, `MyApp::Root`, `MyApp::Person`,
`MyApp::Person::Blogs`, `MyApp::Data`, and `MyApp::View`. A file may retain
`use utf8` where its source text requires it.

`MyApp::Person` and `MyApp::Person::Blogs` import `Int` normally and use
provider-backed parameter paths:

```perl
use Types::Standard qw(Int);

route('/{person_id:&Int}' => \&show_person,
    name => 'show',
);

mount('/{person_id:&Int}/blog',
    router    => MyApp::Person::Blogs->routing,
    namespace => 'blog',
);

route('/{blog_id:&Int}' => \&show_blog,
    name => 'show',
);
```

The example deliberately retains class-method composition:

```perl
sub routing($class) { ... }
sub to_app($class)  { ... }

MyApp::Person->routing;
MyApp::Root->to_app;
```

This leaves room for applications to provide base classes, roles, and method
overrides. The work does not claim that method syntax is universally clearer
than a package function; it preserves the example's chosen extensible style.

The example also retains Router-level and mount-level descriptions. A Router
description documents the component in isolation, while a mount description
may document one placement. Both are metadata, and neither changes dispatch.

The distribution continues to require Perl 5.18. The example README states
its Perl 5.40 minimum. Its repository integration test skips before loading
the example when run under an older Perl, so the example does not silently
raise the supported version of the core distribution.

## 14. Documentation

`PAGI::Routing` documents all four common constraint presentations together:

```perl
# Direct inline regex
route('/users/{id:\d+}' => \&show);

# Named provider
use Types::Standard qw(Int);
route('/users/{id:&Int}' => \&show);

# Explicit reusable object
route('/users/{id}' => \&show,
    constraints => { id => Int },
);

# Explicit per-value predicate
route('/users/{id}' => \&show,
    constraints => { id => sub($value) { ... } },
);
```

The documentation explains:

- provider grammar and the uppercase terminal-name rule;
- declaration-package lookup;
- package-qualified lookup;
- construction-time provider execution;
- accepted provider result shapes;
- synchronous validation without coercion;
- the `[&]Int` literal-regex escape;
- combination with explicit constraints;
- matching and reverse-routing enforcement;
- Type::Tiny integration without `Type::Registry`;
- the lack of module loading, method dispatch, and `AUTOLOAD`; and
- the difference between a provider factory and a returned per-value
  predicate.

`PAGI::Routing::Pattern` documents the private normalized-checker retention
needed by Router composition. The large-example README documents Perl 5.40,
its Type::Tiny example dependency, and the `&Int` spelling. The distribution
Changes file records the new unreleased path syntax and example modernization.

## 15. Verification

### 15.1 Pattern tests

Focused Pattern tests cover:

- an unqualified package-local provider returning a regex;
- an imported-style provider returning a `check` object;
- a provider returning a predicate coderef;
- a fully qualified provider;
- one provider call per declared source Pattern construction;
- matching acceptance and rejection for all three result shapes;
- reverse rendering acceptance and rejection for all three result shapes;
- inline-provider then explicit-constraint ordering;
- provider exceptions with preserved detail;
- missing providers;
- invalid scalar, unblessed, and Future results;
- no provider call during match or render;
- no inherited-method or `AUTOLOAD` lookup;
- no automatic loading of a qualified package;
- lowercase `&name` remaining regex;
- regex expressions such as `&[A-Z]+` remaining regex;
- `[&]Int` and `\&Int` matching literal `&Int`; and
- a missing syntactically valid provider never falling back to regex.

### 15.2 Constructor and protocol tests

Constructor tests prove that the public `route`, `websocket`, `sse`, and
`mount` functions capture the direct declaration package. Tests also cover
direct descriptor construction and ensure already-built descriptors do not
rebind when placed in a Router from another package.

HTTP, raw HTTP, WebSocket, SSE, inline-mount, Router-mount, and opaque-mount
dispatch each receive at least one provider-backed path test. These tests
verify shared grammar; they do not add explicit `constraints` options to
protocol constructors that currently reject them.

### 15.3 Reverse-routing and composition tests

Reverse-routing tests cover:

- a provider-backed named leaf;
- a provider-backed mount parameter;
- a composed route with provider-backed parameters declared in two packages;
- `path_for` and `url_for` rejecting invalid provider-constrained values;
- existing inline regexes remaining enforced during reverse routing;
- explicit and inline constraints both surviving effective-pattern
  construction;
- one Router mounted more than once without provider re-execution; and
- one compiled application serving concurrent requests without shared
  request-local routing state.

### 15.4 Example tests

The large-application integration test continues to use
`PAGI::Test::Client`, run lifespan startup and shutdown, extract rendered
links, and navigate Root, Person, and Blogs. It additionally verifies that:

- the example declares Perl 5.40 syntax;
- numeric `person_id` and `blog_id` paths match through `&Int`;
- a non-integer parameter does not reach the typed leaf;
- generated links remain strings containing the original path values; and
- the test skips cleanly before loading example code on Perl older than 5.40.

POD checks and the complete repository test suite run once under the project's
Perl 5.40 environment. PAGI::Tools does not inherit the unrelated
`campaigns-api` practice of running every suite twice.

## 16. Adversarial findings retained in the design

### 16.1 Namespace dependence

An unqualified provider name depends on the declaration package's installed
functions. This is intentional but must remain visible in documentation.
Ordinary Perl import collisions can replace one package CODE slot with
another; PAGI uses whichever exact function is installed when it constructs
the route. Invalid results fail immediately. Applications that need to avoid
an import collision can use a fully qualified provider.

### 16.2 Base classes and roles

Dynamic subclass lookup would make one route descriptor's meaning depend on
the invocant used to construct it. The design rejects that behavior.
Provider lookup is lexical-package-like and exact. A base or role may import
its own provider or name one fully; subclass-specific constraints remain
explicit application code. Likewise, an application routing-DSL wrapper is
the direct declaration package; it must own the provider import or require a
fully qualified spelling instead of searching outward through callers.

### 16.3 Construction executes application code

The `&` prefix signals that route construction invokes a function. Providers
can throw or perform side effects, but neither route strings nor provider
names come from request input. PAGI performs no string evaluation or dynamic
loading. Documentation recommends deterministic providers, and construction
errors occur before serving.

### 16.4 Regex collision

`&Int` is also a valid regex matching literal `&Int`. The uppercase rule makes
the collision narrow but does not eliminate it. The design reserves that
exact provider-shaped source and keeps the literal value expressible as
`[&]Int` or `\&Int`.

### 16.5 Reverse-routing reconstruction

Provider lookup cannot safely be repeated after Router composition because
mount and leaf constraints may belong to different declaration packages.
Retaining normalized checker records is therefore a correctness requirement,
not merely an optimization. The same change must retain existing inline regex
checkers so dispatch and reverse routing agree.

### 16.6 Mutable checker objects

A provider may return a mutable object or closure. That possibility already
exists for explicit constraints. The descriptor retains and may reuse the
returned checker across compiled applications and concurrent requests.
Constraint implementations are responsible for safe shared use. PAGI does
not clone arbitrary returned objects.

### 16.7 Optional ecosystem dependency

Core PAGI routing only requires a returned object with `check`; it does not
require Type::Tiny. The diagnostic example intentionally demonstrates
`Types::Standard`, so repository test prerequisites include Type::Tiny without
promoting it to a runtime dependency.

## 17. Acceptance criteria

The work is complete when:

1. provider references follow the exact capitalized grammar in this spec;
2. provider functions resolve in the declaration package or exact qualified
   package without inheritance, autoloading, registry lookup, or module load;
3. providers execute synchronously once per declared source Pattern
   construction and return only an existing supported constraint shape;
4. dispatch and reverse routing apply the returned checker without coercion;
5. provider and existing inline-regex checkers survive nested Router
   composition without reparsing or provider re-execution;
6. explicit constraints continue to combine with inline constraints in their
   existing order;
7. literal provider-shaped regex text remains expressible and documented;
8. all shared route and mount path forms honor the same provider grammar;
9. the large application uses Perl 5.40 signatures, retains class-method
   `routing`, and demonstrates `Types::Standard::Int` providers;
10. the core distribution remains Perl 5.18-compatible and has no Type::Tiny
    runtime dependency;
11. focused tests, POD checks, and the full suite pass once under Perl 5.40;
    and
12. documentation clearly distinguishes provider construction, constraint
    checking, validation, and protocol I/O.
