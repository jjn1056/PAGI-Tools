use v5.40;
use Future::AsyncAwait;
use PAGI::Auth qw(auth auth_result unauth_result);
use PAGI::Auth::SimpleUser;
use PAGI::Compose qw(compose);
use PAGI::Middleware::Authentication;
use PAGI::Response qw(json_response);
use PAGI::Routing qw(router route mount middleware);
use PAGI::Utils qw(invoke_app);
use PAGI::Utils::Middleware qw(clone_scope);

{
    package AuthExtensions::Observe;
    sub new { bless {}, shift }
    sub wrap {
        my ($self, $next) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            die 'nested authentication missing' unless PAGI::Auth::auth($scope)->user->identity eq 'inner';
            await PAGI::Utils::invoke_app($next, $scope, $receive, $send);
            return;
        };
    }
}
BEGIN { $INC{'AuthExtensions/Observe.pm'} = __FILE__ }

# Factory middleware at the Compose boundary: a completed result is installed
# in a child scope, and the outer scope remains authoritative to this wrapper.
my $outer = sub ($next) {
    return async sub ($scope, $receive, $send) {
        return await invoke_app($next, $scope, $receive, $send)
            unless ($scope->{type} // '') eq 'http';
        my $result = auth_result(
            user => PAGI::Auth::SimpleUser->new(identity => 'outer'),
            scopes => ['outer:read'],
        );
        my $child = clone_scope($scope, {
            'pagi.auth' => $result,
            'auth.extensions.outer_identity' => $result->user->identity,
        });
        await invoke_app($next, $child, $receive, $send);
        die 'outer context changed' unless auth($child)->user->identity eq 'outer';
        return;
    };
};

my $inner_auth = PAGI::Middleware::Authentication->new(backend => sub ($request) {
    my $grant = ($request->header('Authorization') // '') eq 'Demo inner'
        ? ['notes:edit'] : ['notes:read'];
    return auth_result(
        user => PAGI::Auth::SimpleUser->new(identity => 'inner'),
        scopes => $grant,
    );
});
my $inner_router = router(
    middleware => [middleware(sub ($next) { return $next })],
    routes => [route('/item' => sub ($request) {
        my $context = auth($request);
        my $owner_id = 'inner'; # The resource's trusted owner, not a client claim.
        return json_response({
            identity => $context->user->identity,
            outer => $request->scope->{'auth.extensions.outer_identity'},
            outer_grant_visible => $context->credentials->has('outer:read') ? 1 : 0,
            can_edit => $context->user->is_authenticated
                && $context->user->identity eq $owner_id
                && $context->credentials->has('notes:edit') ? 1 : 0,
        });
    }, middleware => [middleware('+AuthExtensions::Observe')])],
);

compose(
    middleware => [middleware($outer)],
    routes => [
        route('/outer' => sub ($request) {
            return json_response({identity => auth($request)->user->identity});
        }),
        mount('/inner', app => $inner_router,
            middleware => [middleware($inner_auth)]),
    ],
);
