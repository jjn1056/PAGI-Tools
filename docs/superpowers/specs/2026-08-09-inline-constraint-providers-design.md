# Inline Constraint Providers Design

**Date:** 2026-08-09

**Status:** Approved

## 1. Decision

Add an inline constraint-provider form to declarative routing paths:

```perl
use Types::Standard qw(Int);

route('/{person_id:&Int}' => \&show_person);
```

An inline constraint source whose first unescaped character is `&` declares
provider intent rather than a Perl regular expression. The complete source
must then be `&` followed by a valid capitalized package-function name or
construction croaks. PAGI resolves a valid function in the route declaration
package, invokes it with no arguments while constructing the route
description, normalizes its return value through the existing constraint
contract, and stores the resulting predicate record with the immutable path
pattern.

The provider may return any constraint shape already accepted by PAGI:

1. a `Regexp`;
2. a predicate coderef; or
3. a blessed object implementing `check`, with optional `get_message`.

Pattern construction normalizes all three shapes into one private executable
form:

```perl
{
    check   => $predicate,          # always a CODE reference
    explain => $failure_explainer,  # optional CODE reference
}
```

Regex predicates close over an anchored compiled regex. A supplied predicate
is used directly. A check object becomes a predicate that calls `check`; when
the object also implements `get_message`, `explain` calls that method. The
optional explanation affects only reverse-routing diagnostics, never whether
a value is accepted.

The provider itself never runs during request matching or reverse routing.
The normalized predicate does. Constraints remain synchronous validation
and never coerce captured or reverse-routing values.

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

The current explicit constraint form supports Perl-native
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
Type::Tiny `Int` predicate may accept a captured scalar, but the handler still
receives the original decoded scalar. Reverse routing validates the supplied
scalar and then percent-encodes that same value.

## 3. Goals

- Put common named constraints next to their path parameters.
- Reuse the three constraint shapes PAGI already accepts.
- Work naturally with `Types::Standard`, application type libraries, and
  small package-local provider functions.
- Keep Type::Tiny and `Type::Registry` out of the core dependency and lookup
  contract.
- Reserve the complete unescaped-leading-`&` inline-source space so malformed
  provider spellings fail instead of silently becoming regexes.
- Resolve and execute providers at routing-description construction time.
- Normalize every regex, predicate, and check object once into the same
  internal predicate-record form during Pattern construction.
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
- Add a missing-provider fallback hook such as `FIND_ROUTER_CONSTRAINT`.
  Registries can install or export ordinary provider CODE slots under the
  current contract; an exact, non-inherited package hook remains available
  for a later registry design if concrete use warrants the second lookup
  path.
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
- Change `PAGI::App::Router` provider syntax or otherwise level the feature
  sets of the declarative and traditional routers; that requires a separate
  design and plan for the already shipped API.

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

Once the extracted constraint source begins with an unescaped `&`, it belongs
to the provider namespace. It must match the complete grammar above. These are
invalid provider references and croak during construction:

```perl
'/{value:&lower}'
'/{value:&Int }'
'/{value:&[A-Z]+}'
'/{value:&Foo|Bar}'
'/{value:&Foo.*}'
'/{value:&Foo::lower}'
```

The error names the invalid source and parameter, states the capitalized
provider grammar, and points to the `[&]` literal-regex spelling. This rule
turns case mistakes, trailing whitespace, malformed qualifications, and
Unicode lookalikes into construction errors rather than routes that silently
match an unintended literal.

After a source passes the provider grammar, failure to resolve the named
function is also a construction error. Neither malformed nor unresolved
provider intent may fall back to regex compilation.

### 5.2 Literal leading ampersands

In a Perl regular expression, an unescaped `&` is an ordinary literal. PAGI
nevertheless reserves the entire unescaped-leading-`&` inline-source space
for constraint providers. Authors whose regex must begin with a literal
ampersand make that literal explicit:

```perl
route('/{value:[&]Int}'    => \&handler);
route('/{value:[&][A-Z]+}' => \&handler);
route('/{value:\&Int}'     => \&handler);
```

`[&]Int` is the canonical documented escape because it is visibly regex
syntax and does not depend on Perl string escape behavior. The `\&Int`
spelling is valid only when the Perl path string preserves that backslash;
documentation uses a single-quoted string and warns that double-quoted
`"\&Int"` becomes `"&Int"`, which re-enters provider parsing.

This routing API has not been released. Reserving every unescaped-leading-`&`
inline source requires documentation and tests but no compatibility alias or
deprecation period.

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

`route`, `websocket`, and `sse` accept the same explicit `constraints` option
and normalize it through their shared Pattern compiler. Inline and explicit
constraints have identical matching and reverse-routing semantics for every
leaf protocol. The `methods` option remains specific to HTTP routes. Raw
WebSocket and SSE targets may also use constraints because those constraints
select the path before the raw application receives the scope.

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
uses already-normalized predicate records and does not need a declaration
package.

Once a descriptor is built, passing it through another package, Router, or
mount never changes its declaration package or re-resolves its providers.

An ordinary `Exporter` re-export aliases the same constructor coderef into the
application package, so the application remains the direct caller and
declaration package:

```perl
package MyApp::RoutingDSL;

use Exporter 'import';
use PAGI::Routing qw(route);

our @EXPORT_OK = qw(route);
```

Code that imports this alias and calls `route(...)` resolves an unqualified
provider in the consuming package. A re-exported alias does not introduce a
new declaration-package boundary.

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

A routing call written inside a role-defined method belongs to the role
package, even when the method is invoked on a consuming class. The method body
contains the constructor call and remains its direct caller. The role must
therefore import its provider or use a fully qualified provider spelling;
composition into a class does not rebind the declaration package.

### 7.2 Exact subroutine resolution

An unqualified reference such as `&Int` looks for the exact `Int` CODE slot in
the declaration package. An imported function therefore works because it is
installed in that package's symbol table.

A qualified reference such as `&MyApp::Types::PersonId` looks for exactly that
CODE slot. The package must already be loaded by normal Perl code.

The provider's resolution package is the declaration package for an
unqualified reference and the explicitly named package for a qualified
reference. Diagnostics about lookup and invocation name that resolution
package rather than always naming the declaration package.

Exact lookup traverses only existing symbol-table entries and inspects the
terminal CODE slot. Probing must not autovivify a missing package namespace or
symbol glob. For a qualified reference, PAGI can therefore distinguish an
absent package namespace from an existing package that lacks the requested
CODE slot without loading either one.

Provider resolution is exact symbol-table CODE-slot lookup only. It must not
use `$package->can`, `UNIVERSAL::can`, or another method-lookup API. Resolution
must not:

- search `@ISA`;
- perform method dispatch;
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

Each provider occurrence is resolved and invoked exactly once when its
declared source Pattern is constructed. Two occurrences of `&Int` in one path
therefore invoke `Int` twice and produce two independently normalized
predicate records. A provider does not run while the resolver constructs an
effective composed Pattern. No process-global cache is promised: if
application code calls a `routing` method twice and constructs equivalent
route descriptions, every provider occurrence runs once in each source
description.

The result is normalized through the same compiler path as an explicit
constraint:

```text
Regexp                 check => closure over an anchored full-value regex
CODE                   check => the synchronous unary predicate itself
blessed object->check  check => closure calling the object's check method
                        explain => optional closure calling get_message
Future                  provider-specific synchronous-construction error
anything else           generic constraint-shape construction error
```

Future detection is a deliberate provider-specific check performed before
ordinary constraint-shape normalization. It produces the stable `returned a
Future` diagnostic rather than the generic invalid-shape error because an
asynchronous provider is an important contract violation worth identifying
directly. A Future never becomes a predicate record.

The internal execution interface is therefore always
`$record->{check}->($value)`. Matching and rendering do not branch on the
original constraint shape. After invocation they apply the same synchronous
Future guard and truth-value handling to every predicate result.

The distinction between provider and predicate is structural. PAGI invokes
the named provider with no arguments during source construction. If that call
returns a coderef, PAGI stores the returned coderef and later invokes it with
one path value as the predicate.

A check object's optional normalized `explain` callback retains the existing
role of `get_message` in reverse-routing validation errors. Regexes are
anchored with `\A` and `\z`. Normalized predicates receive only the decoded
or reverse-supplied scalar.

A provider may throw. The exception fails construction with context naming
the provider, parameter, and resolution package. A provider returning a
Future fails construction even if that Future would eventually resolve to an
accepted constraint. Provider construction and all later constraint checks
are synchronous.

Provider functions should be deterministic and free of request-specific side
effects. PAGI does not attempt to prove purity. Executing a provider during
construction is comparable to executing any other application factory while
building immutable routing descriptions.

## 9. Matching, explicit constraints, and validation order

The provider's normalized predicate record occupies the same position
currently held by an inline regex constraint. Request matching applies its
`check` coderef to the complete decoded parameter value.

An explicit constraint may still target the same parameter:

```perl
route('/{person_id:&Int}' => \&show_person,
    constraints => {
        person_id => sub($value) { $value > 0 },
    },
);
```

Both constraints must pass. The inline provider predicate runs first,
followed by the explicit predicate, preserving the existing
inline-regex-plus-explicit constraint order.

For request matching:

- a false predicate result makes that declaration a non-match;
- predicate exceptions propagate;
- a Future predicate result is rejected; and
- the accepted captured value remains the original decoded scalar.

For reverse routing:

- missing or extra parameters retain the existing errors;
- a false predicate result croaks with the route and parameter context;
- a normalized `explain` callback may add detail;
- predicate exceptions propagate; and
- the accepted scalar is percent-encoded without conversion.

Provider functions themselves are not called in either request-time path.

## 10. Immutability and composed reverse routing

Normalized predicate records are part of the immutable Pattern description.
Their coderef identities must survive:

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
already-normalized per-parameter predicate-record arrays. Router composition
merges those records by parameter name and supplies them through a private
pre-normalized constructor channel when it builds the effective reverse
Pattern. The composed Pattern receives the normalized records instead of the
original explicit constraint inputs, so no constraint is normalized or
applied twice. Tokenization still recognizes the inline source text but does
not compile its regex or resolve and call its provider a second time. Inline
providers, inline regexes, and explicit constraints all reach composition in
the same predicate-record form. Existing duplicate path-parameter rejection
ensures one composed path cannot contribute two independently named
predicate arrays for the same parameter.

Existing reverse routing already reparses composed paths and enforces inline
regex constraints from mounts and leaves. The predicate-record channel must
preserve that behavior while making reparsing unnecessary for constraint
execution. Its correctness purpose is to keep dispatch and reverse routing on
the identical normalized predicates, including providers whose lookup depends
on each source declaration package and which must not execute again.

Accessor behavior does not change. Public `constraints` accessors continue to
describe the explicit `constraints => {...}` option rather than synthesizing
inline predicate values. The original path string remains available for normal
inspection; normalized predicate records are private immutable composition
data.

## 11. Errors

All provider-definition errors occur during Route, Mount, Pattern, or Router
description construction, before the application handles a request.

Diagnostics must identify the parameter, provider spelling, and resolution
package where applicable. A qualified provider whose package namespace does
not exist gets a distinct diagnostic suggesting that application code load
the defining module before constructing routes. This is guidance, not a claim
that symbol-table presence conclusively proves module-load state.

Required error categories include:

```text
inline constraint provider '&Missing' for parameter 'id' is not defined in package 'MyApp::Routes'
inline constraint provider '&MyApp::Types::PersonId' for parameter 'id' cannot be resolved because package 'MyApp::Types' has no existing symbol table (load the defining module before constructing routes)
inline constraint provider '&MyApp::Types::Missing' for parameter 'id' is not defined in package 'MyApp::Types'
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
For example, an application-local provider may close over a primitive type
and return a narrower predicate:

```perl
sub PersonId() {
    my $int = Int;
    return sub($value) { $int->check($value) && $value > 0 };
}

route('/{person_id:&PersonId}' => \&show_person);
```

The same seam accepts a locally declared Type::Tiny object instead. PAGI
does not distinguish framework types from application types after
normalization.

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

Replacing `qr/\d+/` with `Int` deliberately widens these example routes to
signed integers. Consequently `/person/-1` reaches `show_person` and returns
its branded missing-person response, and reverse routing accepts `-1`. This
demonstrates that provider semantics come from the returned constraint rather
than from the spelling it replaced. An application whose identifiers must be
nonnegative should expose a semantic provider such as `&PersonId` with that
narrower contract.

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

Inline provider references are a `PAGI::Routing` feature.
`PAGI::App::Router` retains its existing `{name:pattern}` grammar, where the
same `&Int` source is ordinary regex text and matches the literal value
`&Int`. Declarations copied between the two routing APIs must translate their
constraints explicitly rather than assuming identical path-string semantics.
Feature parity between the routers is deferred to a separate design and plan.

The documentation explains:

- the choice of a short inline regex for a path-local rule, an inline provider
  for a reusable named semantic constraint beside its parameter, and the
  explicit `constraints` hash for dynamically constructed,
  subclass-dependent, or syntactically complex constraints;
- provider grammar and the uppercase terminal-name rule;
- the reservation of every inline source beginning with unescaped `&`;
- construction errors for malformed provider intent rather than regex
  fallback;
- declaration-package lookup;
- package-qualified lookup;
- construction-time provider execution;
- accepted provider result shapes;
- synchronous validation without coercion;
- the `[&]Int` literal-regex escape;
- the single-quoted `\&Int` alternative and double-quoted-string trap;
- combination with explicit constraints;
- matching and reverse-routing enforcement;
- Type::Tiny integration without `Type::Registry`;
- the lack of module loading, method dispatch, and `AUTOLOAD`; and
- the difference between a provider factory and a returned per-value
  predicate.

The existing `PAGI::Routing` POD sentence that says explicit Perl constraints
are universally clearer is replaced with this choice-based guidance. None of
the three constraint-placement styles is treated as universally preferable.

`PAGI::Routing::Pattern` documents construction-time normalization and the
private predicate-record retention needed by Router composition. The
large-example README documents Perl 5.40, its Type::Tiny example dependency,
and the `&Int` spelling. The distribution Changes file records the new
unreleased path syntax and example modernization.

## 15. Verification

### 15.1 Pattern tests

Focused Pattern tests cover:

- an unqualified package-local provider returning a regex;
- an imported-style provider returning a `check` object;
- a provider returning a predicate coderef;
- a fully qualified provider;
- one provider call per provider occurrence per declared source Pattern
  construction, including two references to one provider in one path;
- matching acceptance and rejection for all three result shapes;
- reverse rendering acceptance and rejection for all three result shapes;
- identical post-normalization synchronous and truth-value handling for all
  three result shapes;
- preservation of a check object's optional failure explanation;
- inline-provider then explicit-constraint ordering;
- provider exceptions with preserved detail;
- missing providers;
- distinct qualified-provider errors for a missing package namespace and an
  existing package without the requested CODE slot;
- failed provider probes not autovivifying package namespaces or symbol
  globs;
- invalid scalar, unblessed, and Future results;
- no provider call during match or render;
- no inherited-method or `AUTOLOAD` lookup;
- no automatic loading of a qualified package;
- lowercase, trailing-space, malformed-qualified, and Unicode-lookalike
  provider spellings failing construction;
- raw regex expressions such as `&[A-Z]+` failing as malformed provider
  intent;
- `[&]Int`, `[&][A-Z]+`, and single-quoted `\&Int` remaining regexes;
- a double-quoted `"\&Int"` path reaching provider parsing because Perl does
  not preserve the backslash; and
- a missing syntactically valid provider never falling back to regex.

### 15.2 Constructor and protocol tests

Constructor tests prove that the public `route`, `websocket`, `sse`, and
`mount` functions capture the direct declaration package. Tests also cover
direct descriptor construction and ensure already-built descriptors do not
rebind when placed in a Router from another package.

Declaration-package tests separately cover an ordinary `Exporter` re-export
remaining bound to the consuming package, a wrapper function becoming the
boundary, and a role-defined routing method remaining bound to the role
package.

HTTP, raw HTTP, WebSocket, SSE, inline-mount, Router-mount, and opaque-mount
dispatch each receive at least one provider-backed path test. These tests
verify shared grammar. Constructor, dispatch, and reverse-rendering tests also
cover explicit regex, predicate, or check-object constraints on WebSocket and
SSE leaves; only HTTP leaves accept `methods`.

### 15.3 Reverse-routing and composition tests

Reverse-routing tests cover:

- a provider-backed named leaf;
- a provider-backed mount parameter;
- a composed route with provider-backed parameters declared in two packages;
- `path_for` and `url_for` rejecting invalid provider-constrained values;
- existing inline regexes remaining enforced during reverse routing;
- explicit and inline constraints both surviving effective-pattern
  construction;
- a side-effecting explicit predicate on a composed named route running
  exactly once for each `path_for` or `url_for` render, proving that the
  pre-normalized channel does not also apply the original constraints hash;
- one Router mounted more than once without provider re-execution; and
- one compiled application serving concurrent requests without shared
  request-local routing state.

### 15.4 Example tests

The large-application integration test continues to use
`PAGI::Test::Client`, run lifespan startup and shutdown, extract rendered
links, and navigate Root, Person, and Blogs. It additionally verifies that:

- the example declares Perl 5.40 syntax;
- numeric `person_id` and `blog_id` paths match through `&Int`;
- `/person/-1` reaches the typed leaf and returns its handler-owned branded
  404;
- a genuinely non-integer parameter does not reach the typed leaf;
- generated links remain strings containing the original path values; and
- the test skips cleanly before loading example code on Perl older than 5.40.

To make the last requirement real, `t/integration-large-application.t`
remains parseable under the distribution's minimum Perl and does not load the
example modules with compile-time `use` statements. After loading the test
framework and establishing the example `lib` path, it performs a version
guard that issues `skip_all` and exits on Perl older than 5.40. Only after
that guard does it load `MyApp::Data`, `MyApp::Person`,
`MyApp::Person::Blogs`, `MyApp::Root`, and `MyApp::View` with runtime
`require` statements.

POD checks and the complete repository test suite run once under an available
Perl >= 5.40 environment. PAGI::Tools does not inherit the unrelated
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

An unescaped `&` is legal literal regex text, but reserving only perfectly
formed capitalized providers would make near-misses such as `&int`, `&Int `,
and `&Foo::lower` silently compile as unintended regexes. The design therefore
reserves every inline source beginning with unescaped `&`. This eliminates the
silent-typo class while keeping literal-leading-ampersand regexes expressible
as `[&]...` or single-quoted `\&...`. The compatibility cost is accepted
because the routing API is unreleased and loud construction errors are safer
than declarations that silently never match their intended values.

### 16.5 Reverse-routing reconstruction

Provider lookup cannot safely be repeated after Router composition because
mount and leaf constraints may belong to different declaration packages.
Retaining normalized predicate records is therefore a correctness
requirement, not merely an optimization. Existing reverse routing already
validates inline regexes; the new channel must preserve that behavior by
carrying their normalized predicates alongside provider and explicit
predicates so dispatch and reverse routing agree.

An alternative considered was retaining the ordered source Pattern chain and
rendering each mount prefix and leaf separately. That would reuse source
predicates by construction, but would require a new cross-pattern layer for
complete parameter validation, parameter partitioning, effective error
labels, root-mount handling, and exact slash joining. It moves representation
risk into path orchestration and replaces the existing single-Pattern
renderer. The design retains the smaller effective-Pattern change; drift is
controlled by carrying the identical normalized predicate coderefs and
testing composed dispatch and rendering together.

### 16.6 Mutable constraint objects and closures

A provider may return a mutable object or closure. That possibility already
exists for explicit constraints. The normalized predicate closure retains the
object or application closure and may be reused across compiled applications
and concurrent requests. Constraint implementations are responsible for safe
shared use. PAGI does not clone arbitrary returned objects.

### 16.7 Optional ecosystem dependency

Core PAGI routing only requires a returned object with `check`; it does not
require Type::Tiny. The diagnostic example intentionally demonstrates
`Types::Standard`, so repository test prerequisites include Type::Tiny without
promoting it to a runtime dependency.

## 17. Acceptance criteria

The work is complete when:

1. every unescaped-leading-`&` source enters provider parsing, valid provider
   references follow the exact capitalized grammar, and malformed provider
   intent croaks without regex fallback;
2. provider functions resolve in the declaration package or exact qualified
   package without inheritance, autoloading, symbol-table autovivification,
   registry lookup, or module load, with diagnostics naming the actual
   resolution package;
3. every provider occurrence executes synchronously once per declared source
   Pattern construction and returns only an existing supported constraint
   shape;
4. Pattern construction normalizes every accepted constraint shape to a CODE
   predicate record with an optional CODE explanation, and execution does not
   branch on the source shape;
5. dispatch and reverse routing apply the same normalized predicates without
   coercion;
6. provider, inline-regex, and explicit predicate records survive nested
   Router composition without renormalization, double application, regex
   recompilation, or provider re-execution;
7. explicit constraints continue to combine with inline constraints in their
   existing order;
8. every literal-leading-ampersand regex remains expressible through `[&]` or
   a preserved `\&`, with the Perl quoting distinction documented;
9. all shared route and mount path forms honor the same provider grammar;
10. HTTP, WebSocket, and SSE leaves accept the same explicit `constraints`
    option and differ only where a feature, such as HTTP methods, is genuinely
    protocol-specific;
11. the large application uses Perl 5.40 signatures, retains class-method
   `routing`, and demonstrates `Types::Standard::Int` providers;
12. the core distribution remains Perl 5.18-compatible and has no Type::Tiny
    runtime dependency;
13. focused tests, POD checks, and the full suite pass once under Perl >=
    5.40; and
14. documentation clearly distinguishes provider construction, constraint
    checking, validation, and protocol I/O.
