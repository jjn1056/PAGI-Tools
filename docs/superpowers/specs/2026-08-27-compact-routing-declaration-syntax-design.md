# Compact Routing Declaration Syntax

**Date:** 2026-08-27

**Status:** Recorded design; implementation deliberately deferred

**Scope:** Add an optional, shape-directed shorthand to the functional and
immutable `PAGI::Routing` constructors and to `PAGI::Compose`, while retaining
the current named forms as the canonical reference API

## 1. Decision

PAGI-Tools will retain its explicit routing declarations:

```perl
route(
    '/apples' => \&list_apples,
    methods   => ['GET'],
    name      => 'list',
);
```

A future implementation may additionally accept this compact equivalent:

```perl
route(['GET'] => '/apples' => \&list_apples, \'list');
```

The compact form is a framing grammar rather than a second routing model:

- an optional leading array reference supplies HTTP methods;
- an optional trailing scalar reference supplies the logical name; and
- the path, target, and any ordinary named options remain between them.

The leading and trailing markers are independent. These are all valid compact
declarations:

```perl
route('/' => \&home);
route('/' => \&home, \'home');
route(['POST'] => '/apples' => \&create_apple);
route(['POST'] => '/apples' => \&create_apple, \'create');
route(
    ['GET'] => '/apples/{apple_id}' => \&read_apple,
    constraints => { apple_id => Int },
    middleware  => [\&authorize],
    desc        => 'Display one apple',
    \'show',
);
```

The shorthand normalizes into the same immutable descriptions as the
canonical form. It does not add matching, dispatch, middleware, naming, or
application semantics.

This document records the design while work proceeds elsewhere. It does not
authorize implementation, planning, release work, or changes to examples.

## 2. Work map

| Repository | Work item | Branch | Base | Owned changes | Deployment boundary | Push target |
| --- | --- | --- | --- | --- | --- | --- |
| `/Users/jnapiorkowski/Desktop/PAGI-Project/PAGI-Tools` | Compact routing declaration syntax | `main` | `main@3bdc712bc8808b728b331c2cac262287c6f56ecb` | This design specification only | Documentation/design; no runtime change | None requested |

Before implementation begins, a fresh work map must record the then-current
base, implementation branch, owned production/tests/docs/examples, and push
target.

## 3. Relationship to the current routing design

This design extends rather than supersedes the implemented 2026-08-26
Starlette-aligned routing-composition design. Its separation of concerns
remains unchanged:

- Route owns complete-path leaf matching and HTTP methods;
- Mount owns prefix-based application composition;
- Router owns ordered selection and routing outcomes;
- middleware transforms applications; and
- Compose owns the deployed root, lifespan, and outer safety boundaries.

The explicit named forms remain canonical because they are self-documenting,
are easiest to generate mechanically, and can express every supported option.
The compact forms are an optional Perl spelling for route tables where repeated
`methods =>` and `name =>` labels obscure the table's request-line shape.

Alignment with Starlette governs the responsibilities of Route, Mount, Router,
middleware, and application composition. Perl may offer an additional syntax
when its reference shapes make that syntax deterministic. The shorthand must
not change what any routing concept means.

## 4. Goals

The compact grammar must:

1. make method-specific route tables read in the order programmers commonly
   think about them: methods, path, handler, name;
2. materially reduce repetition in ordinary declarations;
3. coexist with constraints, middleware, descriptions, raw routes, defaults,
   and lifespan configuration;
4. preserve the canonical named forms without warnings or migration;
5. use Perl value shapes only where those shapes prove the intended role;
6. reject ambiguous coderef roles rather than guessing from arity;
7. normalize before immutable description construction so runtime code has one
   representation; and
8. produce direct diagnostics for mixed or ambiguous spellings.

## 5. Non-goals

This design does not:

- add `get`, `post`, `put`, `patch`, or `delete` functional exports;
- infer a coderef's signature or distinguish handler coderefs from PAGI
  application coderefs by introspection;
- introduce `app(...)`, `native(...)`, or other target-wrapper objects;
- make middleware, constraints, descriptions, defaults, or lifespan callbacks
  positional;
- add names to Router or Compose objects;
- change route matching, Mount ownership, automatic HEAD, 404/405 outcomes,
  reverse routing, or middleware order;
- change the public declaration grammar of `PAGI::App::Router` or
  `PAGI::Endpoint::Router`;
- add class-name application loading; or
- implement the proposal as part of this design-only work.

## 6. Shared grammar principles

### 6.1 Canonical forms remain authoritative

Every existing canonical declaration remains valid:

```perl
route('/x' => \&handler, methods => ['POST'], name => 'create');

mount('/api', app => $api, name => 'api');

my $routing = router(
    routes     => \@nodes,
    middleware => \@middleware,
    desc       => 'Public routes',
);

my $composed = compose(
    app        => $routing,
    middleware => \@middleware,
    lifespan   => \%lifespan,
);
```

POD reference sections should introduce the canonical form first, then show
the compact equivalent. Examples intended to demonstrate tabular route
declarations may prefer the compact form after explaining it.

### 6.2 Shapes may prove roles; coderef arity may not

The compact forms use these values:

| Shape and position | Meaning |
| --- | --- |
| Leading unblessed arrayref to `route` | HTTP methods |
| Final scalar ref on a nameable node | Logical name |
| Positional unblessed arrayref to Mount, Router, or Compose | Structural routes |
| Positional blessed object with `to_app` on Mount or Compose | Application component |
| Coderef after Route's path | Request handler |
| Coderef after Route's explicit `raw` marker | Native PAGI application |
| Coderef after an explicit Mount/Compose `app =>` | Native PAGI application |

An application coderef and a Request-handler coderef have the same Perl
`CODE` shape. The implementation must never inspect signatures, prototypes,
names, or behavior to guess which contract a coderef implements.

### 6.3 Policy stays named

Only high-frequency structural values become positional. These stay named:

```perl
constraints => {...}
middleware  => [...]
desc        => '...'
http_default => $app
lifespan    => {...}
```

This avoids a positional vocabulary that becomes shorter only by requiring the
programmer to memorize option order.

### 6.4 Normalization is construction-time only

The public constructor peels and validates compact markers, converts them to
the canonical option representation, and then invokes the existing immutable
description construction path.

It must not:

- retain the scalar reference used for a name;
- retain mutable aliases to the leading methods array beyond the existing
  normalized method representation;
- call a handler, application, middleware, or `to_app` method;
- perform protocol I/O; or
- introduce a compact-form flag into compiled runtime objects.

## 7. Route

### 7.1 Canonical and compact forms

Canonical:

```perl
route(
    '/apples/{apple_id}' => \&read_apple,
    methods     => ['GET'],
    constraints => { apple_id => Int },
    middleware  => [\&authorize],
    desc        => 'Display one apple',
    name        => 'show',
);
```

Compact:

```perl
route(
    ['GET'] => '/apples/{apple_id}' => \&read_apple,
    constraints => { apple_id => Int },
    middleware  => [\&authorize],
    desc        => 'Display one apple',
    \'show',
);
```

The compact grammar is:

```text
route(
    [ METHODS ]?,
    PATH,
    HANDLER | raw => APPLICATION,
    OPTION => VALUE ...,
    \NAME?,
)
```

The leading methods array and final name reference are independently optional.
Everything between them follows the existing Route grammar.

### 7.2 Parsing order

Route construction performs these conceptual steps:

1. If the first argument is an unblessed arrayref, remove it and record it as
   the positional methods value.
2. If the final argument is a plain scalar reference, remove it, validate its
   referent as the positional name, and copy the string.
3. Parse the remaining path, handler-or-raw target, and named key/value options
   using the existing grammar.
4. Croak if both positional methods and `methods =>` are present.
5. Croak if both a positional name and `name =>` are present.
6. Normalize and validate methods, name, constraints, middleware, description,
   target, and Pattern exactly as the canonical constructor does.

“Plain scalar reference” means `ref($value) eq 'SCALAR'`. Its referent must be
defined, non-reference text satisfying the existing local logical-name rules.
The constructor copies the referent. Mutating a caller-owned scalar after
construction cannot rename the Route.

The positional name must be the final argument. A scalar reference in the
middle is not silently relocated or interpreted.

### 7.3 Default methods and wildcard methods

Omitting the leading array preserves the existing GET default and automatic
HEAD qualification:

```perl
route('/' => \&home, \'home');
```

An explicit method set uses an array even for one method:

```perl
route(['POST'] => '/apples' => \&create_apple, \'create');
route(['GET', 'POST'] => '/search' => \&search, \'search');
route(['*'] => '/*path' => \&catch_all);
```

An empty array, invalid method token, duplicate normalization concern, or
unsupported value fails under the same method-normalization rules as the
canonical `methods =>` option.

### 7.4 Raw routes

The explicit `raw` marker remains mandatory because a raw PAGI application and
a Request handler may both be coderefs:

```perl
# Canonical
route(
    '/webhook' => raw => $webhook_app,
    methods    => ['POST'],
    name       => 'webhook',
);

# Compact
route(['POST'] => '/webhook' => raw => $webhook_app, \'webhook');
```

The shorthand changes neither raw-event ownership nor raw route matching.

## 8. WebSocket and SSE leaves

WebSocket and SSE have no HTTP method set, so only the trailing-name shorthand
applies:

```perl
# Canonical
websocket('/chat/{room}' => \&chat, name => 'chat');
sse('/updates' => \&updates, name => 'updates');

# Compact
websocket('/chat/{room}' => \&chat, \'chat');
sse('/updates' => \&updates, \'updates');
```

Constraints, middleware, and descriptions may remain between the target and
the final name:

```perl
websocket(
    '/chat/{room}' => \&chat,
    constraints => { room => qr/[a-z0-9-]+/ },
    middleware  => [\&authenticate_socket],
    desc        => 'Room socket',
    \'chat',
);
```

A leading arrayref passed to `websocket` or `sse` must fail with a diagnostic
that these leaf types do not accept methods; it must not degrade into a generic
path-string error.

## 9. Mount

### 9.1 Canonical forms

Mount continues to accept exactly one of a child application or structural
routes:

```perl
mount('/api', app => $api_router, name => 'api');

mount(
    '/admin',
    routes => [
        route('/users' => \&users, name => 'users'),
    ],
    name => 'admin',
);
```

### 9.2 Compact application component

An instantiated blessed object with `to_app` proves that it is an application
component:

```perl
mount('/api' => $api_router, \'api');

mount(
    '/static' => PAGI::App::File->app_path('public'),
    middleware => [\&cache_static],
    \'static',
);
```

The constructor validates the component shape but does not invoke `to_app`.
Compilation retains its existing responsibility for resolving the component.

### 9.3 Compact structural routes

An unblessed arrayref in the target position proves structural child routes:

```perl
mount('/admin' => [
    route(['GET'] => '/users' => \&users, \'users'),
    route(['POST'] => '/users' => \&create_user, \'create_user'),
], \'admin');
```

This is exactly equivalent to `routes => [...]`: Mount constructs the child
Router application and retains final prefix ownership.

### 9.4 Native application coderefs stay explicit

This shorthand is intentionally rejected:

```perl
mount('/legacy' => $native_pagi_app);  # ambiguous CODE role
```

The programmer must identify the coderef's contract:

```perl
# Fully canonical
mount('/legacy', app => $native_pagi_app, name => 'legacy');

# Canonical app role plus compact name
mount('/legacy', app => $native_pagi_app, \'legacy');
```

This is a deliberate conservative boundary. The `mount` function could define
every positional coderef as a PAGI application, as Starlette defines Mount's
callable as ASGI. Retaining `app =>` for coderefs makes the three-argument
protocol boundary visible and prevents a Request handler from looking
interchangeable with a native application. The decision may be revisited
before implementation, but an implementation of this recorded design must not
infer coderef arity.

### 9.5 Mount parsing and conflicts

After the path and optional trailing name are removed:

- an unblessed arrayref target means `routes`;
- a blessed target with `to_app` means `app`;
- `app =>` and `routes =>` retain their canonical meanings; and
- a positional coderef receives the explicit ambiguity diagnostic.

Supplying a positional target together with `app =>` or `routes =>` croaks.
Supplying a trailing name together with `name =>` croaks. The same validations
for path, routes, application values, constraints, middleware, descriptions,
and local names apply after normalization.

## 10. Router

Router has one unambiguous primary value: its ordered collection of Route and
Mount descriptions.

```perl
# Canonical
my $routing = router(
    routes       => \@nodes,
    middleware   => [\&request_log],
    http_default => $missing_app,
    desc         => 'Public routes',
);

# Compact structural value; policy stays named
my $routing = router(
    \@nodes,
    middleware   => [\&request_log],
    http_default => $missing_app,
    desc         => 'Public routes',
);
```

The compact grammar is:

```text
router(
    ROUTES_ARRAYREF,
    OPTION => VALUE ...,
)
```

An unblessed leading arrayref means `routes`. Supplying both that value and a
named `routes =>` option croaks. Existing `router()` and fully named behavior
remain unchanged.

Router does not accept a trailing scalar-reference name. A Router is
placement-free; the Mount that places it contributes the namespace segment.
`desc` remains named. Giving `\$text` a different meaning here would destroy
the family-wide rule that a trailing scalar reference always means a logical
route name.

## 11. Compose

Compose accepts either structural routes or one root application. Its compact
primary value is selected only when the value's shape proves the role.

### 11.1 Structural routes

```perl
# Canonical
my $app = compose(
    routes     => \@nodes,
    middleware => [\&logging],
    lifespan   => \%lifespan,
);

# Compact
my $app = compose(
    \@nodes,
    middleware => [\&logging],
    lifespan   => \%lifespan,
);
```

An unblessed leading arrayref means `routes`.

### 11.2 Application components

```perl
# Canonical
my $app = compose(
    app        => $routing,
    middleware => [\&logging],
    lifespan   => \%lifespan,
);

# Compact
my $app = compose(
    $routing,
    middleware => [\&logging],
    lifespan   => \%lifespan,
);
```

A blessed positional object with `to_app` means `app`. This includes a
`PAGI::Routing::Router`, `PAGI::App::File`, or another instantiated component
implementing the shared contract. A blessed array-based component with
`to_app` is an application component, not structural routes; blessedness is
checked before the underlying reference type.

### 11.3 Native application coderefs

As with Mount, a positional coderef is rejected and the role remains explicit:

```perl
compose(
    app        => $native_pagi_app,
    middleware => [\&logging],
);
```

Compose itself supplies enough conceptual context to define a coderef as an
application, so accepting `compose($code)` would be implementable. This design
nevertheless keeps the same conservative rule as Mount: ambiguous native
coderefs use `app =>`; self-describing `to_app` components may be positional.

### 11.4 Compose conflicts

Supplying a positional primary value together with either `routes =>` or
`app =>` croaks. A structural array and an application remain mutually
exclusive. Middleware and lifespan stay named. Compose accepts no trailing
name because it is an application root rather than a named route placement.

## 12. Complete apple example

### 12.1 Canonical declarations

```perl
my $apples = router(
    routes => [
        route('/' => \&list_apples,
            methods => ['GET'], name => 'list'),
        route('/' => \&create_apple,
            methods => ['POST'], name => 'create'),
        route('/{apple_id}' => \&read_apple,
            methods => ['GET'], name => 'show'),
        route('/{apple_id}' => \&update_apple,
            methods => ['PUT'], name => 'update'),
        route('/{apple_id}' => \&delete_apple,
            methods => ['DELETE'], name => 'delete'),
    ],
    desc => 'Apple API',
);

my $routing = router(
    routes => [
        route('/' => \&apple_manager, name => 'home'),
        route('/welcome' => PAGI::Pages->welcome, name => 'welcome'),
        mount('/apples', app => $apples, name => 'apples'),
        route('/*path' => \&not_found, methods => '*'),
    ],
    desc => 'Apple demonstration',
);

my $app = compose(
    app      => $routing,
    lifespan => {
        startup  => \&startup,
        shutdown => \&shutdown,
    },
);
```

### 12.2 Compact declarations

```perl
my $apples = router([
    route(['GET']    => '/'           => \&list_apples,   \'list'),
    route(['POST']   => '/'           => \&create_apple,  \'create'),
    route(['GET']    => '/{apple_id}' => \&read_apple,    \'show'),
    route(['PUT']    => '/{apple_id}' => \&update_apple,  \'update'),
    route(['DELETE'] => '/{apple_id}' => \&delete_apple,  \'delete'),
], desc => 'Apple API');

my $routing = router([
    route('/' => \&apple_manager, \'home'),
    route('/welcome' => PAGI::Pages->welcome, \'welcome'),
    mount('/apples' => $apples, \'apples'),
    route(['*'] => '/*path' => \&not_found),
], desc => 'Apple demonstration');

my $app = compose(
    $routing,
    lifespan => {
        startup  => \&startup,
        shutdown => \&shutdown,
    },
);
```

The compact form removes repeated labels while keeping constraints,
middleware, descriptions, defaults, and lifespan visibly named.

## 13. Equivalence requirements

For every compact declaration there is one canonical declaration. After
construction, the pair must be observably equivalent:

- the same description class and `kind`;
- the same normalized methods and automatic HEAD behavior;
- the same copied local `name`;
- the same path Pattern, constraints, and declaration package;
- the same target and raw/application role;
- the same normalized middleware descriptions;
- the same descriptions, defaults, and lifespan values;
- the same direct-child order and reverse-routing index;
- the same fresh-compilation behavior; and
- the same request-time dispatch and metadata.

No runtime compiler should branch on whether a declaration originated in the
canonical or compact syntax. Introspection should not reveal a syntax-origin
flag.

## 14. Required diagnostics

The implementation must reject at construction time:

```perl
# Duplicate role declarations
route(['GET'] => '/x' => \&x, methods => ['POST']);
route('/x' => \&x, name => 'x', \'x');
mount('/x' => $component, app => $other);
mount('/x' => [route(...)], routes => []);
router([route(...)], routes => []);
compose($component, app => $other);

# Ambiguous positional coderefs
mount('/x' => $possibly_a_handler);
compose($possibly_an_app);

# Invalid name marker
my $undefined_name;
my $reference_name = [];
route('/x' => \&x, \$undefined_name);
route('/x' => \&x, \$reference_name);

# Invalid placement or protocol
route('/x' => \&x, \'x', desc => 'not final');
websocket(['GET'] => '/ws' => \&socket);
sse(['GET'] => '/events' => \&events);
```

Diagnostics should name the constructor and corrective spelling. In
particular:

- positional Mount/Compose coderef errors say to use `app => $code`;
- duplicate positional/named method errors name `methods`;
- duplicate positional/named name errors name `name`;
- misplaced name references say the compact name must be final; and
- WebSocket/SSE leading-array errors say those leaves do not accept methods.

The implementation must identify shorthand conflicts before collapsing named
options into a hash. It must not silently let a named option overwrite a
positional value.

This design does not broaden its scope to define handling of duplicate
canonical key occurrences unrelated to a compact marker. That concern may be
addressed independently.

## 15. Functional and immutable surfaces

The grammar applies equally to exported functions and their matching immutable
constructors:

```perl
route(...)                         # PAGI::Routing export
PAGI::Routing::Route->new(route => ...)

mount(...)                         # PAGI::Routing export
PAGI::Routing::Mount->new(...)

router(...)                        # PAGI::Routing export
PAGI::Routing::Router->new(...)

compose(...)                       # PAGI::Compose export
PAGI::Compose->new(...)
```

The immutable Route class retains its existing leading leaf-kind
discriminator. Compact framing begins after that value:

```perl
PAGI::Routing::Route->new(
    route => ['GET'] => '/apples' => \&list_apples, \'list',
);

PAGI::Routing::Route->new(
    websocket => '/chat' => \&chat, \'chat',
);
```

The exported Route and Mount functions must still capture the user's
declaration package before internal normalization. Compact syntax must not
change inline provider resolution or package-local constraint lookup.

`websocket` and `sse` use the corresponding immutable Route construction path
and receive the trailing-name behavior described above.

## 16. Mutable and method-oriented frontends

`PAGI::App::Router` remains unchanged. It already has compact verb methods and
fluent metadata:

```perl
$r->get('/apples' => \&list_apples)->name('list');
$r->post('/apples' => \&create_apple)->name('create');
$r->mount('/api', app => $api)->name('api');
```

`PAGI::Endpoint::Router` likewise retains method-name handlers and fluent
naming:

```perl
$r->get('/apples' => 'list_apples')->name('list');
$r->mount('/api', app => $self->{api}->to_router)->name('api');
```

Forcing leading method arrays or trailing scalar references onto those APIs
would compete with their existing reasons to exist. Both frontends continue to
produce the same immutable Route, Mount, and Router descriptions internally;
only their public declaration grammar differs.

## 17. Documentation guidance

Future implementation documentation must include:

1. one compact grammar table covering every marker;
2. canonical and compact examples side by side;
3. the rule that options may remain between target and final name;
4. the difference between a Request handler coderef and a native PAGI app;
5. the reason raw Mount/Compose coderefs retain `app =>`;
6. the absence of compact names on Router and Compose;
7. the unchanged imperative frontend spellings; and
8. a recommendation to use canonical forms when metaprogramming or when the
   role of a value is not visually obvious.

Code-generating tools may always emit the canonical forms. They should emit
compact forms only when they implement this complete grammar rather than
guessing from abbreviated examples.

Because the proposal is additive, no existing application requires an
upgrading step. `Changes` should describe the shorthand when implemented, but
`UPGRADING.md` needs only a discoverability note rather than a migration.

## 18. Test requirements for a future implementation

A future plan must cover at least:

### 18.1 Route framing

- leading single, multiple, and wildcard methods;
- omitted methods retaining GET plus HEAD;
- trailing literal and variable scalar-reference names;
- options between target and name;
- handler and explicit raw targets;
- compact/canonical accessor equivalence;
- referent mutation after construction not changing the name;
- declaration-package preservation for inline constraint providers; and
- duplicate, misplaced, empty, and malformed markers.

### 18.2 Protocol leaves

- WebSocket and SSE trailing names with constraints and middleware;
- leading method arrays rejected with protocol-specific diagnostics; and
- compact/canonical metadata and dispatch equivalence.

### 18.3 Mount

- positional `to_app` Router and non-Router components;
- positional structural route arrays;
- blessed array-based `to_app` objects treated as applications;
- explicit native coderef applications;
- positional coderefs rejected;
- positional/named target conflicts;
- trailing names plus intervening options; and
- unchanged prefix rewriting, ownership, reverse lookup, and middleware order.

### 18.4 Router and Compose

- positional structural arrays with every retained named policy option;
- positional application components in Compose;
- explicit native coderef applications in Compose;
- positional/named conflicts;
- no trailing-name interpretation;
- compact/canonical introspection equivalence; and
- fresh independent compilation.

### 18.5 Integration and documentation

- one representative compact application exercised through the PAGI test
  client;
- the canonical and compact apple declarations producing equivalent behavior;
- focused POD examples compiled under the distribution's supported Perl; and
- unchanged mutable and Endpoint frontend tests.

## 19. Adversarial review and tradeoffs

### 19.1 The scalar-reference name is concise but unfamiliar

`\'show'` is not self-explanatory to every Perl programmer. Its value is that
it creates an unambiguous final marker while preserving ordinary strings for
paths, handlers, descriptions, and option keys. The named `name => 'show'`
form remains canonical and available wherever clarity is more important than
table density.

The final scalar-reference position is reserved for nameable declarations.
Adding a future option whose unlabeled value must itself be a scalar reference
would conflict with this grammar; such an option must remain named.

### 19.2 Method-first order improves tables but creates two Route openings

Route may begin with a path string or a methods arrayref. This is deterministic
because paths are strings and method sets are arrays. The benefit is that
method-specific declarations visually align as HTTP request lines. The cost is
one additional grammar branch, confined to construction.

### 19.3 Positional application objects and explicit coderefs are asymmetric

The asymmetry is intentional. An object with `to_app` advertises its contract;
a coderef does not. Requiring `app =>` for the latter applies the same
“explicit jailbreak” principle as Route's `raw` marker. If real applications
show that this distinction creates more friction than safety, a later design
may allow positional coderefs based solely on the containing Mount or Compose
constructor. It must still never guess from coderef arity.

### 19.4 Shortcut proliferation can undermine the Starlette-aligned model

This proposal does not add new concepts. Each shorthand has exactly one
canonical expansion, and all runtime semantics remain in the existing
descriptions and compiler. The explicit API remains the reference surface.
That boundary prevents Perl flexibility from recreating multiple competing
routing models.

## 20. Rejected alternatives

### 20.1 Make every option positional

A form encoding methods, path, target, middleware, constraints, description,
name, and defaults by order would be shorter but unreadable without a reference
card. Only structural high-frequency values receive positional forms.

### 20.2 Infer every Mount and Compose coderef as an application

The containing constructor could supply that meaning, and Starlette uses this
approach for ASGI callables. This design retains the explicit `app =>` marker
for now because Perl cannot distinguish the callable contracts and PAGI-Tools
also prominently uses one-argument Request-handler coderefs.

### 20.3 Introduce an application wrapper helper

Forms such as `mount('/x' => app($code))` or `native($code)` would be
unambiguous, but they add another exported concept merely to remove one option
label. The existing `app =>` spelling is clearer and already documented.

### 20.4 Add HTTP verb function exports

`get('/x' => ...)` and `post('/x' => ...)` are concise, but collide with common
application subroutine names and Perl's `delete` builtin. The method-leading
Route form provides a compact table without expanding the export vocabulary.

### 20.5 Replace canonical forms with compact forms

The compact grammar is useful for hand-written local tables, not a reason to
remove the explicit API. Keeping both is low-risk because compact declarations
normalize immediately into the canonical representation.

## 21. Deferred execution

No implementation plan follows this document until the user deliberately
returns to the proposal and approves implementation. At that time the design
must be checked against the current constructors, examples, supported Perl
versions, and any routing changes landed after 2026-08-27. The future plan must
include all relevant examples, with particular attention to the Starlette
apples comparison, but this design-only commit changes no example today.
