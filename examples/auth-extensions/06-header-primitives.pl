use v5.40;
use PAGI::Auth qw(www_authenticate);
use PAGI::Headers;
use PAGI::Response qw(json_response);
use PAGI::Utils::Headers qw(parse_authorization_bearer);

# Independent utility functions also work without a Request or Headers object.
say 'extracted: ', parse_authorization_bearer('Bearer accepted');

my $formatted = www_authenticate('Bearer', realm => 'notes');
say 'formatter: ', $formatted;

my $headers = PAGI::Headers->new;
$headers->add('WWW-Authenticate', www_authenticate('Basic', realm => 'staff'));
$headers->add('WWW-Authenticate', $formatted);
say 'repeated: ', join(' | ', $headers->get_all('WWW-Authenticate'));

# A token68 challenge is opaque: pass it as a raw field value.
$headers->set('WWW-Authenticate', 'Negotiate YWJj');
say 'opaque: ', $headers->get('WWW-Authenticate');
say 'digest: ', www_authenticate('Digest', realm => 'notes', qop => 'auth,auth-int');
# Digest algorithm and stale are unquoted, so use a complete raw field value.
$headers->set('WWW-Authenticate',
    'Digest realm="notes", nonce="example-nonce", qop="auth", algorithm=SHA-256, stale=true');
say 'digest raw: ', $headers->get('WWW-Authenticate');

# This constructs a resource_metadata header only; it does not implement
# discovery, token acquisition, OAuth, or MCP methods.
my $response = json_response({ error => 'An access token is required.' },
    status => 401,
);
$response->headers->set('WWW-Authenticate',
    'Bearer realm="notes", resource_metadata="https://notes.example/.well-known/oauth-protected-resource/mcp"',
);
say 'metadata: ', $response->header('WWW-Authenticate');

my $denied = json_response({ error => 'Read access required.' }, status => 403);
$denied->headers->set('WWW-Authenticate',
    www_authenticate('Bearer', realm => 'notes', error => 'insufficient_scope',
        scope => 'notes:read'));
say 'insufficient: ', $denied->status, '; ', $denied->header('WWW-Authenticate');
