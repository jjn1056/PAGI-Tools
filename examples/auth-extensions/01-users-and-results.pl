use v5.40;
use Future;
use PAGI::Auth qw(auth auth_result unauth_result www_authenticate);
use PAGI::Auth::SimpleUser;
use PAGI::Auth::UnauthenticatedUser;

{
    package AuthExtensions::Guest;
    sub new { bless {}, shift }
    sub is_authenticated { 0 }
    sub identity { '' }
    sub display_name { 'Visitor' }
}
{
    package AuthExtensions::Auth;
    use parent 'PAGI::Auth';
    sub unauth_result {
        my ($self, %args) = @_;
        $args{user} = AuthExtensions::Guest->new unless exists $args{user};
        return $self->SUPER::unauth_result(%args);
    }
}

my $factory = AuthExtensions::Auth->new;
my $guest = $factory->unauth_result(scopes => ['catalog:read']);
die 'guest subclass failed' unless $guest->user->display_name eq 'Visitor';
die 'guest grant lost' unless $guest->credentials->has('catalog:read');
die 'base guest changed' unless PAGI::Auth::unauth_result()->user->display_name eq '';
die 'built-in guest failed' if PAGI::Auth::UnauthenticatedUser->new->is_authenticated;
say 'guest: ', $guest->user->display_name, '; authenticated: ',
    $guest->user->is_authenticated ? 1 : 0;
say 'guest grant: ', $guest->credentials->has('catalog:read') ? 1 : 0;

my $user = PAGI::Auth::SimpleUser->new(identity => 'alice', display_name => 'Alice');
my @grants = ('manager', 'notes:edit');
my $result = auth_result(user => $user, scopes => \@grants);
my $rejected = unauth_result(failure => {
    message => 'note rejected', code => 'expired',
});
my $scope = { 'pagi.auth' => $result };
my @forms = (
    [auth($scope), auth_result(user => $user), unauth_result(), www_authenticate('Bearer')],
    [PAGI::Auth->auth($scope), PAGI::Auth->auth_result(user => $user),
        PAGI::Auth->unauth_result(), PAGI::Auth->www_authenticate('Bearer')],
    [PAGI::Auth->new->auth($scope), PAGI::Auth->new->auth_result(user => $user),
        PAGI::Auth->new->unauth_result(), PAGI::Auth->new->www_authenticate('Bearer')],
    [$factory->auth($scope), $factory->auth_result(user => $user),
        $factory->unauth_result(), $factory->www_authenticate('Bearer')],
);
for my $row (@forms) {
    die 'helper form failed' unless $row->[0]->user->identity eq 'alice'
        && $row->[1]->user->is_authenticated
        && !$row->[2]->user->is_authenticated
        && $row->[3] eq 'Bearer';
}
say 'helper forms: function class instance new';
say 'result: ', $result->user->identity, '; ', $rejected->failure->message,
    '; ', $rejected->failure->code;
die 'omitted code should be undefined'
    if defined unauth_result(failure => { message => 'only message' })->failure->code;
my $completed = Future->done($result);
say 'future: ', $completed->get->user->identity;

my $creds = $result->credentials;
my $can_edit = sub ($c) {
    return $c->has('admin') || $c->has_all('manager', 'notes:edit');
};
my $admin = auth_result(user => $user, scopes => ['admin'])->credentials;
my $viewer = auth_result(user => $user, scopes => ['notes:read'])->credentials;
say 'scope policy: admin=', $can_edit->($admin) ? 1 : 0,
    ' manager-edit=', $can_edit->($creds) ? 1 : 0,
    ' viewer=', $can_edit->($viewer) ? 1 : 0;
die 'scope helper failed' unless $creds->has_any('admin', 'manager')
    && !$creds->has_any() && $creds->has_all() && !$creds->has('admin');
my @copy = @{$creds->scopes};
push @grants, 'notes:read';
say 'live scopes: ', $creds->has('notes:read') ? 1 : 0,
    '; copy unchanged: ', @copy == 2 ? 1 : 0;
