use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);

use PAGI::Auth::SimpleUser;
use PAGI::Auth::UnauthenticatedUser;
use PAGI::Auth::Credentials;
use PAGI::Auth::Failure;
use PAGI::Auth::Result;

my $guest = PAGI::Auth::UnauthenticatedUser->new;
ok !$guest->is_authenticated, 'the built-in guest is unauthenticated';
is [$guest->identity, $guest->display_name], ['', ''],
    'guest accessors return neutral empty strings';
unlike $guest->display_name, qr/anonymous|guest|visitor/i,
    'the built-in guest does not imply an application display label';

my $user = PAGI::Auth::SimpleUser->new(identity => '0');
ok $user->is_authenticated, 'a simple user is authenticated';
is $user->identity, '0', 'false-looking scalar identities are preserved';
is $user->display_name, '0', 'display name defaults to identity';

my $named = PAGI::Auth::SimpleUser->new(
    identity     => '42',
    display_name => 'Alice',
);
is $named->display_name, 'Alice', 'an explicit display name is preserved';

like dies { PAGI::Auth::SimpleUser->new }, qr/identity/i,
    'simple user identity is required';
like dies { PAGI::Auth::SimpleUser->new(identity => undef) }, qr/identity/i,
    'simple user identity must be defined';
like dies { PAGI::Auth::SimpleUser->new(identity => []) }, qr/identity/i,
    'simple user identity must be a scalar';

my $scopes = ['notes:read'];
my $grants = PAGI::Auth::Credentials->_new($scopes);
is refaddr($grants->scopes), refaddr($scopes),
    'credentials retain the supplied scopes array';
ok !$grants->has('notes:write'), 'a missing scope is false';
push @$scopes, 'notes:write';
ok $grants->has_all('notes:read', 'notes:write'),
    'membership sees a grant added after construction';
ok !$grants->has('Notes:Read'), 'scope matching is case-sensitive';
ok !$grants->has_any(), 'has_any is false for no requirements';
ok $grants->has_all(), 'has_all is true for no requirements';
like dies { $grants->has_all(['notes:read']) }, qr/scope/i,
    'scope lists are passed flat';

splice @$scopes, 0, 1;
ok !$grants->has('notes:read'),
    'membership sees a grant removed after construction';
$scopes->[0] = 'notes:publish';
ok !$grants->has('notes:write'),
    'membership sees a grant changed after construction';
ok $grants->has('notes:publish'), 'the changed grant is available';

my $source = ['catalog:read'];
my $copied = PAGI::Auth::Credentials->_new([@$source]);
push @$source, 'catalog:write';
ok !$copied->has('catalog:write'),
    'callers can request snapshot semantics with an explicit copy';

like dies { $grants->has() }, qr/exactly one scope/i,
    'has rejects a missing scope';
like dies { $grants->has('one', 'two') }, qr/exactly one scope/i,
    'has rejects multiple scopes';
like dies { $grants->has(undef) }, qr/scope/i,
    'has rejects an undefined scope';
like dies { $grants->has({}) }, qr/scope/i,
    'has rejects a reference scope';
like dies { $grants->has_any('notes:publish', undef) }, qr/scope/i,
    'has_any validates every requirement after a match';
like dies { $grants->has_all('missing', []) }, qr/scope/i,
    'has_all validates every requirement after a mismatch';

like dies { PAGI::Auth::Credentials->_new(undef) }, qr/scopes/i,
    'credentials require a scopes array';
like dies { PAGI::Auth::Credentials->_new({}) }, qr/scopes/i,
    'credentials reject a non-array scopes reference';
like dies { PAGI::Auth::Credentials->_new(['read', undef]) }, qr/scope/i,
    'credentials reject an undefined grant';
like dies { PAGI::Auth::Credentials->_new(['read', []]) }, qr/scope/i,
    'credentials reject a reference grant';

my $failure = PAGI::Auth::Failure->_new({ message => 'Token rejected' });
is $failure->message, 'Token rejected', 'failure exposes its safe message';
is $failure->code, undef, 'failure code is optional';

my $coded_failure = PAGI::Auth::Failure->_new({
    message => 'Token expired',
    code    => 'token_expired',
});
is $coded_failure->code, 'token_expired',
    'failure exposes an application-defined code';

for my $bad_failure (
    undef,
    [],
    {},
    { message => undef },
    { message => [] },
    { message => 'bad', code => undef },
    { message => 'bad', code => [] },
) {
    like dies { PAGI::Auth::Failure->_new($bad_failure) }, qr/message|code|hash/i,
        'failure rejects malformed fields';
}

my $result = PAGI::Auth::Result->_new(
    user        => $named,
    credentials => $grants,
    failure     => $coded_failure,
);
is refaddr($result->user), refaddr($named),
    'result preserves the supplied user object';
is refaddr($result->credentials), refaddr($grants),
    'result preserves the supplied credentials object';
is refaddr($result->failure), refaddr($coded_failure),
    'result preserves the supplied failure object';

done_testing;
