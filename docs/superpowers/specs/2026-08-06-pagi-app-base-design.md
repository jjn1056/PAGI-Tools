# PAGI::App Route-Component Base Design

**Date:** 2026-08-06
**Status:** Approved design; implementation deferred

## 1. Priority and status

This specification records an approved shape for a small `PAGI::App` base
class. It is not approved for immediate implementation planning.

The large-application example exposed two earlier routing gaps:

1. reverse routing across opaque component mounts; and
2. cooperative no-match bubbling through routing-aware component mounts.

Work on those gaps takes priority. After that work, this design must be checked
against the resulting routing and mount contracts before an implementation plan
is written. Recording the design now preserves the decisions without allowing
this convenience abstraction to determine the shape of the more fundamental
routing work.

## 2. Context

`examples/15-large-application` divides one application into `MyApp::Root`,
`MyApp::Person`, and `MyApp::Person::Blogs`. The packages are independently
compiled PAGI components and are mounted opaquely by class name.

Person and Blogs repeat the same small shell:

```perl
sub to_app {
    return router(
        routes => [ ... ],
    )->to_app;
}
```

Root has a genuinely different responsibility. It owns the deployed
application's Compose and lifespan boundary:

```perl
sub to_app {
    return compose(
        routes   => [ ... ],
        lifespan => { ... },
    )->to_app;
}
```

The repeated route-component shell is modest, but the example also demonstrates
why configured component instances and a compilation preparation hook would be
useful in larger applications.

## 3. Competition and design lesson

`Plack::Component` supplies construction, `prepare_app`, and `to_app`, while a
subclass implements the raw request-time `call($env)` method. The object then
persists across requests. This is a good low-level endpoint contract, but a
literal port would not improve PAGI route packages: it would push them toward
raw `($scope, $receive, $send)` handling or require each package to compile and
delegate to its own router.

Starlette and Rack rely more heavily on callable application protocols.
Starlette commonly composes `Router` and other mountable ASGI applications;
Rack accepts any object implementing `call(env)` and uses `Rack::Builder` for
assembly. PAGI already has the corresponding interoperability convention in
`PAGI::Utils::to_app`, which accepts native coderefs, component objects, and
loadable component class names.

The missing abstraction is therefore not another raw PAGI protocol. It is a
thin, optional base for route-owning application packages.

References:

- <https://metacpan.org/pod/Plack%3A%3AComponent>
- <https://www.starlette.io/applications/>
- <https://www.starlette.io/routing/>
- <https://github.com/rack/rack/blob/main/SPEC.rdoc>

## 4. Goals

- Remove the repeated route-component `to_app` shell.
- Keep Router, Compose, and lifespan ownership visible.
- Provide a synchronous preparation hook at the `to_app` boundary.
- Make configured component instances useful without adding an attribute DSL.
- Provide explicit instance-method binding for route handlers and other
  callbacks.
- Preserve class-name mounting as the zero-configuration form.
- Preserve fresh routing and middleware compilation on every `to_app` call.
- Remain compatible with Perl 5.18 and add no dependency.

## 5. Non-goals

- Change existing `PAGI::App::*` inheritance in this work.
- Port the raw `Plack::Component::call` contract.
- Automatically choose Compose when lifecycle-looking methods exist.
- Add an attribute system, option schema, dependency container, or controller
  discovery mechanism.
- Accept method-name strings directly in `route` or other routing constructors.
- Change middleware levels, Router behavior, Compose behavior, or lifespan
  ownership.
- Solve opaque-mount reverse routing or cooperative no-match bubbling.
- Make request-specific application-object state safe or desirable.

## 6. Chosen abstraction

`PAGI::App` is an additive base class for route-owning application packages.
Its public methods are:

```text
new
prepare_app
action
routes
router_options
router
build_app
to_app
```

The module exports nothing. Applications opt in through ordinary inheritance:

```perl
use parent 'PAGI::App';
```

Existing modules such as `PAGI::App::File`, `PAGI::App::Cascade`, and
`PAGI::App::Router` keep their current inheritance and behavior. Retrofitting
them, if ever useful, requires separate evidence and a separate compatibility
review.

### 6.1 Constructor

`new` accepts either key/value pairs or one hashref and stores a shallow copy:

```perl
my $default = MyApp::Person->new;

my $configured = MyApp::Person->new(
    repository => $repository,
    features   => $features,
);

my $from_hash = MyApp::Person->new({
    repository => $repository,
});
```

An odd key/value list, a single non-hashref argument, or mixing a hashref with
additional arguments is a synchronous constructor error. `PAGI::App` does not
generate accessors or validate subclass-specific keys. A subclass owns that
validation and may provide ordinary Perl accessors.

The constructor copies only the outer hash. Referenced collaborators retain
their identity deliberately.

### 6.2 `prepare_app`

The default `prepare_app` is a no-op:

```perl
sub prepare_app { return }
```

`to_app` invokes it synchronously once for every compilation, before
`build_app`, `routes`, or `router_options` are evaluated. Its return value is
ignored. A subclass may use it to:

- validate constructor options;
- resolve filesystem paths;
- precompute immutable lookup tables; or
- construct collaborators captured by bound actions.

It must not perform asynchronous startup work. Connections, worker pools, and
other resources requiring ordered acquisition and release belong in Compose
lifespan callbacks. A thrown exception propagates synchronously from `to_app`.

`prepare_app` must be repeatable because an existing object may be compiled
more than once.

### 6.3 `action($method)`

`action` explicitly binds an instance method and returns an ordinary coderef:

```perl
sub routes {
    my ($self) = @_;

    return [
        route('/' => $self->action('list_people'), name => 'index'),
    ];
}

sub list_people {
    my ($self, $c) = @_;
    return $c->html(...);
}
```

Binding fails synchronously unless the name is a defined, non-reference,
unqualified method name matching `\A[A-Za-z_]\w*\z` that `$self->can`.
Inherited methods are valid. The returned closure captures the exact object
and forwards every argument without conversion:

```perl
return sub { return $self->$method(@_) };
```

The callback consumer determines the signature. A route action receives
`($self, $context)`. A bound Compose lifespan callback receives
`($self, $state, $scope)`. Immediate and Future-backed results continue to be
normalized by the existing Router or Compose consumer; `action` adds no async
layer.

Routing constructors continue to require coderefs. This design does not make
`route('/' => 'list_people')` magical.

### 6.4 `routes`, `router_options`, and `router`

`routes` is required. The base implementation croaks with a direct subclass
contract error. A subclass returns an arrayref of ordinary declarative routing
nodes:

```perl
sub routes {
    my ($self) = @_;

    return [
        route('/' => $self->action('list_people'), name => 'index'),
        route('/{person_id}' => $self->action('show_person'),
            name        => 'show',
            constraints => { person_id => qr/\d+/ },
        ),
        mount('/{person_id}/blog' => 'MyApp::Person::Blogs',
            constraints => { person_id => qr/\d+/ },
        ),
    ];
}
```

`router_options` defaults to an empty hashref. It may provide any current
`PAGI::Routing::Router` option except `routes`:

```perl
sub router_options {
    return {
        desc       => 'Person component',
        middleware => [\&with_person_context],
    };
}
```

The `routes` key is rejected because `routes()` is the single source of the
component's route list. Unknown options and invalid values are rejected by the
ordinary Router constructor.

`router` validates the two hook return shapes and creates a fresh immutable
Router description. The following is illustrative; the base may call
`PAGI::Routing::Router->new` directly rather than importing the functional
constructor:

```perl
router(
    routes => $self->routes,
    %{$self->router_options},
)
```

`router` is a documented subclass construction helper. It does not invoke
`prepare_app`; only `to_app` owns preparation. Calling `router` directly is not
an alternative application deployment lifecycle.

### 6.5 `build_app`

The default `build_app` returns `$self->router`. This is sufficient for
ordinary route components.

Root overrides `build_app` because it explicitly owns Compose and lifespan:

```perl
sub build_app {
    my ($self) = @_;

    return compose(
        app      => $self->router,
        lifespan => {
            startup  => $self->action('startup'),
            shutdown => $self->action('shutdown'),
        },
    );
}
```

The override returns a component description, not necessarily a native
coderef. It may return anything accepted by `PAGI::Utils::to_app`.

The base class does not inspect `startup`, `shutdown`, or middleware-looking
methods and does not silently change the application kind. The deployed Root's
special ownership remains visible in code.

### 6.6 `to_app`

`to_app` accepts either class or object invocation:

```perl
MyApp::Person->to_app;
MyApp::Person->new(repository => $repository)->to_app;
```

Class invocation constructs a fresh zero-configuration object. Object
invocation uses the exact supplied instance. It then:

1. calls `prepare_app`;
2. calls `build_app`;
3. rejects an undefined result;
4. rejects a result identical to `$self`, which would recurse through component
   coercion; and
5. returns `PAGI::Utils::to_app($built_component)`.

Subclasses normally override `routes`, `router_options`, `prepare_app`, or
`build_app`, not `to_app`. Perl does not enforce a final method, but overriding
`to_app` opts out of this contract.

## 7. Compilation and object lifetime

The normal compilation sequence is:

```text
class or object
  -> construct when invoked as a class
  -> prepare_app
  -> build_app
     -> router by default
        -> routes
        -> router_options
  -> PAGI::Utils::to_app
  -> native PAGI coderef
```

Every `to_app` call creates a fresh Router and middleware graph. Existing PAGI
compilation semantics remain unchanged.

Bound actions capture the application object, which therefore persists for the
compiled application's lifetime and may be invoked concurrently. The object
may contain configuration and prepared shared collaborators. It must never
store a request context, scope, path parameters, response events, or other
request-specific mutable state.

Identity sharing is explicit:

- `MyApp::Person->to_app` creates a fresh instance for that compilation;
- `$instance->to_app` compiles that exact instance; and
- compiling the same instance more than once intentionally shares its object
  state while still producing fresh routing graphs.

## 8. Resulting example shape

`MyApp::Person` and `MyApp::Person::Blogs` inherit from `PAGI::App`, define
instance actions and `routes`, and delete their repeated `to_app` methods.

`MyApp::Root` also inherits from `PAGI::App`. It defines `routes`, may use
`prepare_app` for repeatable path/configuration preparation, and overrides
`build_app` to wrap `$self->router` with Compose lifespan.

The loader remains unchanged:

```perl
MyApp::Root->to_app;
```

Opaque class-name mounts remain unchanged:

```perl
mount('/person' => 'MyApp::Person');
```

A configured placement uses an instance and already works with PAGI component
coercion:

```perl
mount('/person' => MyApp::Person->new(
    repository => $repository,
));
```

This design does not alter mount ownership, route names, generated outcomes,
or reverse-routing visibility.

## 9. Error contract

The following failures occur synchronously during construction or `to_app`:

- malformed constructor arguments;
- a missing `routes` implementation;
- a non-arrayref `routes` result;
- a non-hashref `router_options` result;
- `routes` appearing in `router_options`;
- a missing action method;
- an undefined or self-identical `build_app` result; and
- ordinary Router, Compose, or `PAGI::Utils::to_app` validation failures.

`PAGI::App` adds no runtime error interception and sends no protocol events of
its own.

## 10. Compatibility and documentation

The feature is additive. `PAGI::Utils::to_app` already recognizes both class
and object components with `to_app`. Router mounts, Compose, the middleware
builder, cascades, and `PAGI::Test::Client` therefore require no new component
shape.

`PAGI::Compose` documentation currently explains that it was not named
`PAGI::App` because that name would imply a base class for the `PAGI::App::*`
namespace. That explanation must be updated: `PAGI::App` now deliberately is
the optional application-package base, while `PAGI::Compose` remains the
explicit root assembler.

Documentation must distinguish:

- compile-time `prepare_app` from runtime lifespan startup;
- persistent application-object state from request state;
- default Router construction from explicit Root Compose construction; and
- the new convenience base from the unchanged raw PAGI application protocol.

## 11. Verification requirements

Implementation, when scheduled, must use test-driven development and cover:

1. key/value and hashref constructors, shallow-copy behavior, and malformed
   arguments;
2. class versus object `to_app` identity;
3. `prepare_app` ordering, synchronous failure, and repeated compilation;
4. action validation, exact object capture, argument forwarding, and immediate
   and Future-backed handler completion through a real router;
5. required `routes` and both hook return-shape errors;
6. propagation of Router `middleware`, `desc`, `not_found`, and
   `method_not_allowed` options;
7. rejection of `routes` inside `router_options`;
8. fresh Router and middleware construction on repeated `to_app` calls;
9. undefined and self-identical `build_app` results;
10. explicit Root `build_app` composition and lifespan startup/shutdown;
11. concurrent in-flight requests against one compiled application without
    base-class request-state leakage;
12. conversion of the large-application example while preserving its complete
    `PAGI::Test::Client` behavior matrix;
13. unchanged existing `PAGI::App::*` behavior and inheritance; and
14. Perl 5.18 syntax compatibility, full-suite verification, POD checks, and
    distribution build verification.

## 12. Deferred next step

Do not write the implementation plan for this specification yet. First return
to the earlier large-application routing gaps. Once that work has settled the
opaque-mount contracts, re-read this specification, resolve any resulting
conflicts explicitly, and then decide whether `PAGI::App` still earns its
place.
