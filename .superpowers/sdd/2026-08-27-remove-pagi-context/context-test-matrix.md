# Context test disposition matrix

Each listed name is a former top-level subtest. `TRANSFER` names the owning
direct test and its target subtest; `ALREADY` identifies coverage present before
this task. `DELETE` is intentionally rejected wrapper-only behavior.

## Factory and shared helpers

`01-factory.t`:

- module loads and has expected methods — DELETE -> Context factory, spec §5.
- _type_map returns expected mapping — DELETE -> type map, spec §5.
- _resolve_class returns correct subclass — DELETE -> factory assertion, spec §5.
- unmapped explicit type uses a generic Context once per factory and type — DELETE -> fallback factory, spec §5.
- new returns correct subclass — DELETE -> factory dispatch, spec §5.
- scope accessors work — ALREADY -> t/request-stash.t: class and factory accept PAGI::Request sources.
- scope accessor defaults — ALREADY -> t/request-stash.t: path_param only returns path params, not query params.
- host is inherited and validates Host consistently across protocols — TRANSFER -> t/authority.t: Request and protocol objects expose their raw scopes to Host validation.
- protocol introspection — DELETE -> Context type assertions, spec §6.
- header lookup — ALREADY -> t/request/01-basic.t: multiple headers with same name returns last value.
- path_params and path_param — ALREADY -> t/request-stash.t: param returns route parameters from scope.
- path_param strict mode — ALREADY -> t/request-stash.t: param returns route parameters from scope.
- path_params defaults to empty hashref — TRANSFER -> t/request-stash.t: protocol objects retain direct default path parameter access.
- path_param works on WebSocket context — TRANSFER -> t/request-stash.t: protocol objects retain direct default path parameter access.
- receive and send accessors — DELETE -> Context raw callback exposure, spec §6.

`02-shared.t`:

- stash accessor; stash shared across protocol helpers — ALREADY -> t/request-stash.t: stash lives in scope.
- session accessor; session dies without middleware; has_session — ALREADY -> t/middleware/session/helper.t: class and factory accept PAGI::Request sources.
- state accessor; state defaults to empty hashref — ALREADY -> t/request-state.t: absent state is optional.
- connection state without connection object; connection state with mock connection; on_complete delegates to connection — DELETE -> generic Context delegation, spec §6.
- csrf_token accessor; csrf_verify — ALREADY -> t/csrf-helper.t: verification accepts only matching nonempty submitted values.

`03-http.t`:

- HTTP context has correct methods; method accessor; request accessor; response accessor; request and response share scope; req and resp aliases; full HTTP round-trip — DELETE -> HTTP Context wrapper/accumulator sugar, spec §§5–6; Request and Response own the retained contracts.

`03-response-value.t`:

- ctx->response is a detached accumulator; ctx->respond sends it — DELETE -> accumulator sugar; Response is a value and Compose/server owns cross-emission enforcement.
- ctx->respond guards double-send — DELETE -> Context double-send enforcement; Compose/server owns cross-emission enforcement.

`assert-type.t`:

- assert_http passes on http, croaks on the others; assert_websocket; assert_sse; reads as a one-line gate chained off new — DELETE -> Context type assertions, spec §§5–6.

`http-sugar.t`:

- text() returns a Response value sent as text/plain; html() returns text/html; json() with opts sets body, content-type, and status; redirect() sets status and location; sugar operates on the one cached response accumulator — DELETE -> Context response sugar/accumulator, spec §6; Response owns response construction.

`raw-send.t`:

- SSE context: raw_send bypasses the ->send override; HTTP context: raw_send equals the raw send; WebSocket context: raw_send equals the raw send — DELETE -> raw Context callback delegation, spec §6.

## Wrapper extension, router, and dispatcher behavior

`04-websocket.t`:

- WebSocket context has correct methods; websocket accessor; shared methods work on WebSocket context — DELETE -> WebSocket Context wrapper, spec §6.
- WebSocket accept round-trip — ALREADY -> t/websocket/03-lifecycle.t: accept sends websocket.accept event.

`05-sse.t`:

- SSE context has correct methods; sse accessor; shared methods work on SSE context — DELETE -> SSE Context wrapper, spec §6.
- SSE send event round-trip — ALREADY -> t/sse/04-send.t: send_event with all fields.

`06-extension.t`:

- custom _type_map adds new protocol; custom _type_map replaces built-in type; custom _resolve_class overrides resolution logic; mapped extensions do not warn and each factory warns separately for unmapped types — DELETE -> factory extension hooks, spec §5.

`07-router.t`:

- App Router HTTP handlers receive one Request while Context remains available — ALREADY -> t/endpoint/01-http-constructor.t: HTTP handlers are Request-first.
- App Router WebSocket and SSE handlers receive direct protocol objects — ALREADY -> t/endpoint/07-websocket-to-app.t: app creates a WebSocket wrapper and calls handle; t/endpoint/09-sse-lifecycle.t: lifecycle via to_app.
- native middleware can add Request-visible helper state — ALREADY -> t/request-state.t: application state is separate from request stash.
- routing metadata enables relative Request reverse routing — ALREADY -> t/routing/13-url-helper.t: real compiled frames follow the active Router placement.

`08-dispatcher.t`:

- on() returns $self for chaining; on() handler receives ($ctx, $event); multiple handlers for same type run in registration order; run() returns disconnect on websocket.disconnect; run() returns disconnect on sse.disconnect; run() returns stop when stop() called from handler; run() returns error when receive fails; auto-terminate on disconnect without registered handler; registered handler for disconnect fires before exit; events before disconnect are dispatched first; stop() does not fire handlers for subsequent events; on_error fires on receive failure with source=receive; on_error fires on handler exception with source=handler; on_error returns $self for chaining; multiple on_error callbacks run in order; on_error falls back to warn when not registered (receive); on_error falls back to warn when not registered (handler); exception in on_error callback does not prevent others; handler exception does not stop the loop; async handlers are awaited; async on_error callbacks are awaited; async on_error exception does not prevent other callbacks; run() croaks if called while already running; on() called from within handler does not affect current iteration; unhandled event types silently ignored; PAGI_DEBUG warns on unhandled non-terminal events; PAGI_DEBUG does not warn for terminal event without handler; handler table cleared after loop exits; context GCd after run() when handler captured object; run() throws synchronously when already running; on_default fires for an unhandled event; a type-specific handler takes precedence over on_default; on_default does not fire for the terminal disconnect; on_default errors route to on_error(handler) and it is async-aware; on_default returns $self — DELETE -> generic Context dispatcher, spec §6.

## WebSocket direct ownership

`09-websocket-delegation.t`:

- accept delegates to ws; accept with subprotocol; accept with headers — ALREADY -> t/websocket/03-lifecycle.t: accept sends websocket.accept event; accept with subprotocol; accept with headers.
- close delegates to ws; close with code and reason — ALREADY -> t/websocket/03-lifecycle.t: close sends websocket.close event; close with code and reason.
- supports_denial_response delegates to ws; deny delegates to ws; deny falls back to close when extension absent — ALREADY -> t/websocket/denial-response.t: supports_denial_response() returns 1 when extension present; deny() with extension present sends two events and marks closed; deny() falls back to websocket.close when extension absent.
- send_text delegates; send_bytes delegates; send_json delegates — ALREADY -> t/websocket/04-send.t: send_text sends text frame; send_bytes sends binary frame; send_json encodes and sends as text.
- try_send_text delegates; try_send_bytes delegates; try_send_json delegates; send_text_if_connected delegates; send_bytes_if_connected delegates; send_json_if_connected delegates — ALREADY -> t/websocket/05-safe-send.t: try_send_text returns true on success; try_send_bytes works like try_send_text; try_send_json works like try_send_text; send_text_if_connected sends when connected; send_bytes_if_connected sends when connected; send_json_if_connected sends when connected.
- receive_text delegates; receive_bytes delegates; receive_json delegates — ALREADY -> t/websocket/06-receive.t: receive_text returns text content; receive_bytes returns binary content; receive_json decodes JSON text.
- each_message delegates; each_text delegates; each_bytes delegates; each_json delegates — ALREADY -> t/websocket/07-iteration.t: each_message iterates until disconnect; each_text iterates text frames; each_bytes iterates binary frames; each_json iterates and decodes.
- is_connected uses WS state (not base class); is_closed delegates — TRANSFER -> t/websocket/08-cleanup.t: on_close callback runs on disconnect.
- subprotocols delegates; keepalive delegates — ALREADY -> t/websocket/03-lifecycle.t: accept with subprotocol; t/websocket-heartbeat.t: keepalive sends websocket.keepalive event.
- query delegates; query_params delegates; raw_query delegates; raw_query_params delegates — ALREADY -> t/websocket-query-params.t: query shortcut; query_params basic parsing; raw mode skips UTF-8 decoding.
- header_all delegates; http_version delegates — ALREADY -> t/websocket/01-constructor.t: scope property accessors; header accessors.
- on() is Context dispatcher, not WS on(); on_error() is Context dispatcher, not WS on_error(); run() is Context dispatcher, not WS run(); _sync_terminal_disconnect is a no-op when ->ws was never touched; on_close() croaks with a pointer to the underlying object; ws() and websocket() still return underlying object — DELETE -> Context dispatcher/delegation, spec §6.
- ws on_close fires and state syncs on $ctx->run terminal disconnect — TRANSFER -> t/websocket/08-cleanup.t: on_close callback runs on disconnect.

## SSE direct ownership

`10-sse-delegation.t`:

- start delegates to sse; start with options — ALREADY -> t/sse/03-start.t: start sends sse.start event; start with custom status and headers.
- close delegates — ALREADY -> t/sse/12-close-event.t: close() sends an sse.close event carrying the reason.
- send delegates; send_json delegates; send_event delegates; send_comment delegates — ALREADY -> t/sse/04-send.t: send sends data-only event; send_json encodes as JSON; send_event with all fields; send_comment sends a direct SSE comment event.
- try_send delegates; try_send_json delegates; try_send_comment delegates; try_send_event delegates — ALREADY -> t/sse/05-safe-send.t: try_send returns true on success; try_send_json works; try_send_event works; try_send_comment succeeds with a direct comment event.
- is_started delegates; is_closed delegates — ALREADY -> t/sse/02-state.t: initial state is pending; state transitions.
- last_event_id delegates — ALREADY -> t/sse/07-last-event-id.t: last_event_id returns header value.
- keepalive delegates — ALREADY -> t/sse/08-keepalive.t: keepalive sends sse.keepalive event; t/sse/14-keepalive-deferred-arm.t: start() arms a pending keepalive immediately after sse.start.
- query_param delegates; query_params delegates; raw_query_param delegates; raw_query_params delegates; header_all delegates; http_version delegates — DELETE -> Context forwarding surface, spec §6; direct protocol metadata remains owned by PAGI::SSE.
- each delegates — ALREADY -> t/sse/09-iteration.t: each iterates over arrayref.
- on() is Context dispatcher, not SSE on(); on_error() is Context dispatcher, not SSE on_error(); run() is Context dispatcher, not SSE run(); _sync_terminal_disconnect is a no-op when ->sse was never touched; on_close() croaks with a pointer to the underlying object; sse() still returns underlying object — DELETE -> Context dispatcher/delegation, spec §6.
- sse on_close fires and state syncs on $ctx->run terminal disconnect — TRANSFER -> t/sse/06-lifecycle.t: run waits for disconnect and calls on_close.
- decline() delegates to the underlying object — ALREADY -> t/sse/13-decline.t: decline sends sse.http.response.start + sse.http.response.body(more=>0).

`11-sse-connection-state.t`:

- Context::SSE is_connected uses SSE state (not base/pagi.connection) — DELETE -> Context override, spec §6.
- PAGI::SSE->is_connected mirrors is_started && !is_closed — TRANSFER -> t/sse/02-state.t: initial state is pending; state transitions.

## Reverse routing

`12-routing-reverse.t`:

- Context reverse methods lazily delegate to the URL compatibility facade — DELETE -> Context compatibility facade, spec §6.
- Context selects the last resolver from a valid routing frame stack — ALREADY -> t/routing/13-url-helper.t: operations read the selected frame at operation time.
- Context resolves from a supplied mounted Router child frame; Context terminal navigation always denotes a namespace; Context uses a supplied root Resolver and selected namespace — ALREADY -> t/routing/13-url-helper.t: absolute and relative references preserve traversal and capture rules.
- Context prefers an exact leaf that shares a namespace address — ALREADY -> t/routing/13-url-helper.t: an exact leaf wins at a shared namespace address.
- Context inheritance selects only target path keys and never invents suffixes — ALREADY -> t/routing/13-url-helper.t: capture inheritance selects target keys only.
- Context path_for and url_for share compact and named reverse arguments; Context reverse methods share operation-specific argument failures — ALREADY -> t/routing/13-url-helper.t: compact and named params-query-fragment forms are equivalent.
- all built-in Context subclasses inherit routing reverse methods — TRANSFER -> t/routing/13-url-helper.t: direct protocol sources preserve a mounted child boundary.
- missing and malformed routing metadata fail at the Context boundary; compiled routers reject a non-scalar current root_path boundary — ALREADY -> t/routing/13-url-helper.t: missing malformed and versioned routing frames fail at operation time.
- Context reverses supplied child-boundary frames across protocols — TRANSFER -> t/routing/13-url-helper.t: direct protocol sources preserve a mounted child boundary.
- Context reverse generation inherits captures and applies each composed predicate once — ALREADY -> t/routing/13-url-helper.t: Type::Tiny, regex, coderef, and protocol constraints remain active.
- Context paths add root_path only at the application boundary; Context URI-encodes decoded root_path without re-encoding generated paths; Context encodes supplied mounted captures exactly once — ALREADY -> t/routing/13-url-helper.t: root_path and nested Mount boundaries are applied exactly once; decoded boundaries and generated suffixes encode exactly once.
- url_for uses validated Host and only absent Host permits server fallback; url_for maps the request scheme according to the named route kind — ALREADY -> t/routing/13-url-helper.t: authority validation and target kinds preserve HTTP HTTPS WS WSS mappings.
- documented HTTP proxy and Host middleware order feeds routing URL generation — TRANSFER -> t/routing/13-url-helper.t: ReverseProxy normalizes authority before TrustedHosts and url_for.
