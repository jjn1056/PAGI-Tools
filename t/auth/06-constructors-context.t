#!/usr/bin/env perl
use strict;
use warnings;

use Future;
use Scalar::Util qw(refaddr);
use Test2::V0;

use lib 'lib';
use PAGI::Auth qw(auth auth_result unauth_result);
use PAGI::Auth::Result;
use PAGI::Auth::SimpleUser;

{
    package Local::ScopeSource;
    sub new { return bless { scope => $_[1] }, $_[0] }
    sub scope { return $_[0]{scope} }
}

{
    package Local::Guest;
    sub new { return bless {}, $_[0] }
    sub is_authenticated { return 0 }
    sub identity { return '' }
    sub display_name { return 'Visitor' }
}

{
    package Local::Auth;
    use parent 'PAGI::Auth';
    sub unauth_result {
        my ($self, @args) = @_;
        my %args = @args;
        $args{user} = Local::Guest->new unless exists $args{user};
        return $self->SUPER::unauth_result(%args);
    }
}

my $user = PAGI::Auth::SimpleUser->new(identity => 'alice');
my $scopes = ['notes:read'];
my $result = auth_result(user => $user, scopes => $scopes);
is refaddr($result->user), refaddr($user), 'authenticated result retains user';
is refaddr($result->credentials->scopes), refaddr($scopes),
    'authenticated result retains scopes';
is $result->failure, undef, 'authenticated result has no failure';

my $scope = { type => 'http', 'pagi.auth' => $result };
is auth($scope)->user->identity, 'alice', 'raw scope resolves context';
is auth(Local::ScopeSource->new($scope))->user->identity, 'alice',
    'object scope source resolves context';
ok !auth($scope)->credentials->has('authenticated'),
    'constructor does not insert authenticated grant';

my $rejected = unauth_result(failure => { message => 'Not accepted' });
isa_ok $rejected, 'PAGI::Auth::Result';
ok !$rejected->user->is_authenticated, 'default user is a guest';
is $rejected->failure->code, undef, 'failure code is optional';
is $rejected->failure->message, 'Not accepted', 'failure message is retained';

my $guest_scopes = ['catalog:read', 'authenticated'];
my $guest = Local::Guest->new;
my $granted_guest = unauth_result(user => $guest, scopes => $guest_scopes);
is refaddr($granted_guest->user), refaddr($guest),
    'guest result retains supplied user';
is refaddr($granted_guest->credentials->scopes), refaddr($guest_scopes),
    'guest result retains supplied scopes';
ok $granted_guest->credentials->has('authenticated'),
    'guest flag is independent of authenticated grant';

my $authenticated_without_grant = auth_result(user => $user);
ok !$authenticated_without_grant->credentials->has('authenticated'),
    'authenticated flag does not create a grant';

my $guest_one = unauth_result();
my $guest_two = unauth_result();
isnt refaddr($guest_one->user), refaddr($guest_two->user),
    'omitted guests are fresh';
isnt refaddr($guest_one->credentials->scopes),
    refaddr($guest_two->credentials->scopes), 'omitted scopes are fresh';
is ref($result), ref($guest_one), 'both constructors return the same class';

my @bad_auth = (
    ['missing context', sub { auth({ type => 'http' }) }, qr/pagi\.auth/],
    ['undefined context', sub { auth({ 'pagi.auth' => undef }) }, qr/Result/],
    ['hash context', sub { auth({ 'pagi.auth' => {} }) }, qr/Result/],
    ['bare user', sub { auth({ 'pagi.auth' => $user }) }, qr/Result/],
    ['Future context', sub { auth({ 'pagi.auth' => Future->done($result) }) }, qr/Result/],
    ['factory context', sub { auth({ 'pagi.auth' => PAGI::Auth->new }) }, qr/Result/],
    ['no source', sub { auth() }, qr/exactly one/],
    ['too many sources', sub { auth({}, {}) }, qr/exactly one/],
    ['bad source', sub { auth([]) }, qr/scope hashref/],
    ['bad source scope', sub { auth(Local::ScopeSource->new([])) }, qr/scope hashref/],
);
for my $case (@bad_auth) {
    like dies { $case->[1]->() }, $case->[2], $case->[0];
}

my $false_member = bless {}, 'Local::FalseMember';
{
    no strict 'refs';
    *{'Local::FalseMember::is_authenticated'} = sub { 0 };
    *{'Local::FalseMember::identity'} = sub { 'member' };
    *{'Local::FalseMember::display_name'} = sub { 'Member' };
}

my @bad_results = (
    ['missing authenticated user', sub { auth_result() }, qr/user.*required/i],
    ['undefined authenticated user', sub { auth_result(user => undef) }, qr/user/],
    ['bare authenticated user', sub { auth_result(user => {}) }, qr/user/],
    ['incomplete user', sub { auth_result(user => bless({}, 'Local::Incomplete')) }, qr/user/],
    ['false authenticated user', sub { auth_result(user => $false_member) }, qr/authenticated/i],
    ['true guest user', sub { unauth_result(user => $user) }, qr/unauthenticated/i],
    ['non-array scopes', sub { unauth_result(scopes => {}) }, qr/scopes/],
    ['undefined scope', sub { unauth_result(scopes => [undef]) }, qr/scope/],
    ['reference scope', sub { unauth_result(scopes => [[]]) }, qr/scope/],
    ['odd options', sub { unauth_result('scopes') }, qr/key\/value|pairs/i],
    ['unknown option', sub { unauth_result(mode => 'guest') }, qr/unknown.*mode/i],
    ['duplicate option', sub { unauth_result(scopes => [], scopes => []) }, qr/duplicate.*scopes/i],
);
for my $case (@bad_results) {
    like dies { $case->[1]->() }, $case->[2], $case->[0];
}

my @factories = (
    ['exported', undef],
    ['base class', 'PAGI::Auth'],
    ['base instance', PAGI::Auth->new],
    ['chained new', PAGI::Auth->new],
    ['subclass', 'Local::Auth'],
    ['subclass instance', Local::Auth->new],
);
for my $case (@factories) {
    my ($name, $invocant) = @$case;
    my $made = $name eq 'exported'
        ? auth_result(user => $user)
        : $invocant->auth_result(user => $user);
    isa_ok $made, 'PAGI::Auth::Result';

    my $anonymous = $name eq 'exported'
        ? unauth_result()
        : $invocant->unauth_result();
    my $expected_guest = $name =~ /subclass/ ? 'Local::Guest'
        : 'PAGI::Auth::UnauthenticatedUser';
    isa_ok $anonymous->user, $expected_guest;

    my $installed = { 'pagi.auth' => $made };
    my $observed = $name eq 'exported' ? auth($installed)
        : $invocant->auth($installed);
    is $observed->user->identity, 'alice', "$name auth";
}

isa_ok unauth_result()->user, 'PAGI::Auth::UnauthenticatedUser';

my $factory_one = PAGI::Auth->new;
my $factory_two = PAGI::Auth->new;
isnt refaddr($factory_one), refaddr($factory_two), 'new creates shareable factories';
like dies { auth({ 'pagi.auth' => $factory_one }) }, qr/Result/,
    'factory never becomes a current result';
like dies { auth({ 'pagi.auth' => $factory_two }) }, qr/Result/,
    'another factory never acquires invocation data';
like dies { PAGI::Auth->new(mode => 'strict') }, qr/does not accept options/i,
    'factory takes no configuration';

done_testing;
