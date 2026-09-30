package NotesDemo::TokenStore;
use v5.40;
use Future;

# Public demo credentials, with no issuer, database, or expiry machinery.
sub new ($class) {
    return bless { records => {
        'alice-reader' => {
            user_id => 'alice', display_name => 'Alice',
            scopes => ['authenticated', 'notes:read'],
        },
        'alice-editor' => {
            user_id => 'alice', display_name => 'Alice',
            scopes => ['authenticated', 'notes:read', 'notes:write'],
        },
        'export-service' => {
            user_id => 'export-bot', display_name => 'Note exporter',
            scopes => ['notes:read'],
        },
        'read-write' => {
            user_id => 'alice', display_name => 'Alice',
            scopes => ['notes:read', 'notes:write'],
        },
        'write-only' => {
            user_id => 'alice', display_name => 'Alice', scopes => ['notes:write'],
        },
        'case-reader' => {
            user_id => 'alice', display_name => 'Alice', scopes => ['Notes:Read'],
        },
        'no-scopes' => {
            user_id => 'alice', display_name => 'Alice', scopes => [],
        },
    } }, $class;
}

sub find_active ($self, $token) {
    return Future->done($self->{records}{$token});
}

1;
