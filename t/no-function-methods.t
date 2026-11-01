use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Compose ();
use PAGI::CSRF ();
use PAGI::ErrorContext ();
use PAGI::Middleware::Session ();
use PAGI::Request ();
use PAGI::Response::JSON ();
use PAGI::Routing::OpenAPI ();
use PAGI::Routing::URL ();
use PAGI::Session ();
use PAGI::Stash ();
use PAGI::Transport ();

# A class's exported functions are imported, not inherited: its objects
# answer none of them as methods.

ok(!PAGI::Response::JSON->can('response'), 'a Response subclass has no response method');
ok(!PAGI::Request->can('http_connection'), 'a Request has no http_connection method');

ok(!PAGI::Stash->can('stash'), 'a Stash has no stash method');
ok(!PAGI::Session->can('session'), 'a Session has no session method');
ok(!PAGI::ErrorContext->can('error_context'), 'an ErrorContext has no error_context method');
ok(!PAGI::Transport->can('transport'), 'a Transport has no transport method');
ok(!PAGI::CSRF->can('csrf'), 'a CSRF has no csrf method');
ok(!PAGI::Compose->can('compose'), 'a Compose has no compose method');
ok(!PAGI::Routing::OpenAPI->can('openapi'), 'an OpenAPI has no openapi method');
ok(!PAGI::Routing::OpenAPI->can('openapi_document'), 'an OpenAPI has no openapi_document method');
ok(!PAGI::Middleware::Session->can('session_state'), 'the Session middleware has no session_state method');
ok(!PAGI::Middleware::Session->can('session_store'), 'the Session middleware has no session_store method');
ok(!PAGI::Routing::URL->can('url'), 'a URL facade has no url method');

# path_for and url_for are documented methods of the facade.
ok(PAGI::Routing::URL->can('path_for'), 'a URL facade has path_for');
ok(PAGI::Routing::URL->can('url_for'), 'a URL facade has url_for');

done_testing;
