package NotesDemo::TokenStore;
use v5.40;
use Future;

# Public demo credentials, with no issuer, database, or expiry machinery.
# Extra records (token => record) join the three demo tokens.
sub new ($class, %extra) {
    return bless { records => {
        'alice-reader' => {
            user_id => 'alice', display_name => 'Alice', scopes => ['notes:read'],
        },
        'alice-editor' => {
            user_id => 'alice', display_name => 'Alice',
            scopes => ['notes:read', 'notes:write'],
        },
        'export-service' => {
            user_id => 'export-bot', display_name => 'Note exporter',
            scopes => ['notes:read'],
        },
        %extra,
    } }, $class;
}

sub find_active ($self, $token) {
    return Future->done($self->{records}{$token});
}

1;
