# Final whole-branch review

Reviewed range: `c4c007f7a0603c2e36cd88266f2289db4f3baa12..b5b04551bb07010471b4857cdf8dd65f6af090fe` (42 commits, 98 files). Review used focused source/diff passes, the final brief and continuation rulings, Auth Phase 1 requirements, and the current sibling Www specification. Historical superseded event names and File restrictions were not treated as runtime requirements. No source/index/HEAD mutation, subagents, full-suite rerun, build rerun, or negative-control mutation was performed.

## Strengths

- Auth remains a one-way policy layer over Pages: immutable challenge values, strict construction, separate repeated authentication fields, known Bearer status rules, and open extension errors. Credential acquisition and identity state have not leaked into the layer.
- Refusal emission uses the original scope and ordinary HTTP events, with start commitment observed after send settlement. File and Stream use the established response delivery machinery rather than an additional event translator.
- WebSocket/SSE helpers use authoritative connection facts and one retained cleanup worker. Peer Close metadata remains distinct from lifecycle reason/detail; cancellation observers do not own server sends. Endpoint and router completion boundaries close only active accepted/started helpers.
- Tests meaningfully exercise pending sends, cancellation, weak-reference lifetime, asynchronous cleanup, deferred notifications, and real HTTP/1.1 and HTTP/2 refusal termination. The cookie example clearly labels its demo policy and deployment omissions; modern example syntax is version-gated.

## Issues

### Critical (Must Fix)

None found.

### Important (Should Fix)

1. **P2 — Negotiated HTTP materialization mutates its source scope.**
   - Location: `lib/PAGI/Pages/Application.pm:54`, through `lib/PAGI/Pages.pm:197` and `lib/PAGI/Pages.pm:826`.
   - `response_for` passes an HTTP source through unchanged to the Pages policy, as specified. Default `as => auto` negotiation then creates a metadata-only Request against that same hash; `header_all` installs `pagi.request.headers` into the caller's scope. This violates the new public no-source-mutation guarantee. The existing mutation tests cover synthesized non-HTTP views; the general HTTP materialization test uses fixed JSON and bypasses negotiation.
   - Reproduced with `perlbrew exec --with perl-5.42.2@default perl -Ilib -MPAGI::Auth=challenge,bearer -e 'my $scope = { type => "http", headers => [["accept", "text/plain"]] }; my $page = challenge(challenges => [bearer(realm => "api")]); print "before=", join(",", sort keys %$scope), "\n"; my $response = $page->response_for($scope); print "after=", join(",", sort keys %$scope), "\n"; print "cache=", ref($scope->{"pagi.request.headers"}), "\n";'`.
   - Actual output: `before=headers,type`; `after=headers,pagi.request.headers,type`; `cache=PAGI::Headers`.
   - Action: isolate the metadata-only Request's cache writes while preserving the original HTTP scope identity at the descriptor and policy hooks. Add a regression using negotiated raw HTTP and Request sources, including uncached and already-cached headers, asserting source keys/cache identity remain unchanged and negotiation still uses repeated fields correctly. Do not solve this by changing the prescribed original-scope policy seam or weakening the public guarantee.

### Minor (Nice to Have)

2. **P3 — `response_for` POD incorrectly rejects custom request-like scopes.**
   - Location: `lib/PAGI/Pages/Application.pm:114`.
   - The method says it rejects unknown scope types. Its implementation, Phase 1 section 11.1, and `t/pages/07-response-for.t` explicitly accept any defined nonempty scalar type except lifespan. This obscures the intended reusable custom-protocol materialization seam.
   - Action: document custom request-like types as accepted for metadata materialization, with emission owned by their protocol adapter. Keep `to_app`'s HTTP-only restriction explicit.

3. **P3 — Response application-boundary POD retains the removed HTTP-only restriction.**
   - Location: `lib/PAGI/Response.pm:97` and `lib/PAGI/Response.pm:101`.
   - The paragraph says a Response application croaks on WebSocket/SSE scopes. `_validate_http_triplet` now deliberately permits both, and the branch's refusal architecture relies on ordinary HTTP Response emission on those original scopes. This is a concrete migration contradiction rather than a wording preference.
   - Action: distinguish HTTP response event vocabulary from supported scope types; state that preaccept/prestart refusal can run on WebSocket/SSE scopes, retain the recommendation to use the lifecycle helpers, and retain rejection of lifespan/unsupported types.

## Recommendations

Apply one bounded fix wave for the HTTP cache isolation and the two POD corrections. Verify the new regression plus affected Pages/Auth and documentation checks; there is no finding here that calls for another architecture layer, a Phase 2 expansion, or repeating the entire integration campaign.

The reported final evidence is 226 files / 2,582 tests passing, including seven real integration cases, with only the optional RELEASE_TESTING skip; subsequent changes were documentation-only with scoped checks and archive rebuild. This review inspected that evidence and the substantive test mechanisms but does not claim to have rerun those commands. Its only executed behavioral probe was the HTTP mutation reproduction above. No additional runtime blocker was established in the connection, refusal, cancellation, fixture, or example passes.

## Assessment

**Ready to merge? With fixes.**

The architecture and exercised lifecycle boundaries are coherent and portable to the current public connection contract. The reproducible HTTP materialization mutation should be corrected before declaring Phase 1 complete; the two small public-contract documentation errors can be addressed in the same bounded pass.
