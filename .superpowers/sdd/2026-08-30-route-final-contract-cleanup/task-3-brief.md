### Task 3: Document the Standalone Route Boundary and Endpoint-Classification Ruling

**Files:**

- Modify: `lib/PAGI/Routing/Route.pm` POD
- Modify: `docs/superpowers/specs/2026-08-30-route-endpoints-and-application-valued-responses-design.md`
- Modify: `t/upgrading-routing-composition.t`
- Modify: `t/00-pod/cookbook-examples.t` only if the existing synchronization test belongs there; otherwise keep the new assertions in `t/upgrading-routing-composition.t`

**Interfaces:**

- Consumes: existing `Route->to_app` behavior through `PAGI::Routing::Compiler->compile($route)`.
- Produces: precise public documentation for standalone 404, 405/Allow, HEAD, lifespan, and missing Compose safety layers; an explicit design ruling that no `endpoint_kind` accessor exists.

- [ ] **Step 1: Add documentation synchronization assertions.**

In `t/upgrading-routing-composition.t`, read the Route POD and assert that its `to_app` section names all of these behaviors:

```text
stock negotiated 404 for a path miss
stock 405 with Router-authoritative Allow for a method mismatch
HEAD wire suppression
inert lifespan completion without receive/send activity
no Compose ErrorHandler, response-completion guard, or lifespan orchestration
```

Also assert the design specification contains the endpoint-classification ruling and does not promise a separate normalized endpoint-kind accessor.

- [ ] **Step 2: Run the documentation test and confirm RED.**

Run:

```bash
prove -lv t/upgrading-routing-composition.t
```

Expected: the new synchronization assertions fail against the terse existing `to_app` POD and the old section 8.5 wording.

- [ ] **Step 3: Expand `Route->to_app` POD without changing behavior.**

After the existing one-node Router sentence, add prose equivalent to:

```text
The compiled application is a complete routing boundary. A path miss invokes
the stock negotiated Pages 404. A path match with a method mismatch invokes
the stock Pages 405 and reasserts the Router-authoritative Allow header. Its
HEAD boundary preserves calculated headers while suppressing body and file
delivery. Lifespan completes inertly without reading or sending events.

This direct routing boundary does not install Compose's lifespan
orchestration, ErrorHandler, or response-completion guard. Deploy through
Compose when those outer application guarantees are required.
```

Do not claim Pages receives the lifespan scope; the routing compiler returns before default dispatch.

- [ ] **Step 4: Record the no-`endpoint_kind` ruling.**

Replace section 8.5’s ambiguous sentence:

```text
Router compilation preserves the declared endpoint and records its normalized
kind for introspection.
```

with:

```text
Router compilation preserves the exact declared endpoint. Route exposes the
protocol kind (`route`, `websocket`, or `sse`) through `kind`; it does not
publish a second handler/application classification accessor. Top-level CODE
versus instantiated-object shape is the canonical endpoint classification,
and compilation normalizes that value without replacing the declared
`endpoint` accessor.
```

Add the same decision as a short adversarial ruling in section 21 so it cannot be mistaken for an accidentally omitted implementation:

```text
### “Endpoint classification needs another accessor”

Declined. The public endpoint value already carries the complete structural
classification: CODE means a one-argument protocol handler, while an
instantiated `to_app` object means a native PAGI application. A duplicate
`endpoint_kind` value could drift and has no current consumer.
```

- [ ] **Step 5: Run documentation and POD checks and confirm GREEN.**

Run:

```bash
prove -lv t/upgrading-routing-composition.t t/00-pod/cookbook-examples.t
podchecker lib/PAGI/Routing/Route.pm lib/PAGI/Routing/Mount.pm
```

Expected: PASS with both POD files reporting `pod syntax OK`.

- [ ] **Step 6: Commit.**

```bash
git add \
  lib/PAGI/Routing/Route.pm \
  lib/PAGI/Routing/Mount.pm \
  docs/superpowers/specs/2026-08-30-route-endpoints-and-application-valued-responses-design.md \
  t/upgrading-routing-composition.t \
  t/00-pod/cookbook-examples.t
git commit -m "docs: clarify standalone Route behavior"
```

Only add a test file to the commit if Task 3 actually changed it.

---
