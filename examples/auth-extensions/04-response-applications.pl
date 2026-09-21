use v5.40;
use Future::AsyncAwait;
use PAGI::Auth qw(auth auth_result unauth_result www_authenticate);
use PAGI::Auth::SimpleUser;
use PAGI::Compose qw(compose);
use PAGI::Pages;
use PAGI::Response qw(json_response);
use PAGI::Routing qw(route mount middleware router);
use PAGI::Utils qw(as_app_object invoke_app);

{
    package AuthExtensions::NoticeApp;
    sub new { bless { response => $_[1] }, $_[0] }
    sub to_app { $_[0]->{response}->to_app }
}

my $backend = sub ($request) {
    return ($request->header('Authorization') // '') eq 'Bearer accepted'
        ? auth_result(user => PAGI::Auth::SimpleUser->new(identity => 'alice'))
        : unauth_result(failure => { message => 'Sign in to continue.' });
};
my $ok = sub ($request) {
    return json_response({ identity => auth($request)->user->identity });
};
my $notice = sub ($request) {
    return json_response({ error => auth($request)->failure->message }, status => 401);
};

my $group = sub ($next) {
    return async sub ($scope, $receive, $send) {
        unless (auth($scope)->user->is_authenticated) {
            await invoke_app(json_response({ error => 'Group sign-in required.' }, status => 401),
                $scope, $receive, $send);
            return;
        }
        await invoke_app($next, $scope, $receive, $send);
        return;
    };
};

compose(
    middleware => [middleware('Authentication', backend => $backend)],
    routes => [
        route('/sync' => sub ($request) {
            return $notice->($request) unless auth($request)->user->is_authenticated;
            return $ok->($request);
        }),
        route('/async' => async sub ($request) {
            return $notice->($request) unless auth($request)->user->is_authenticated;
            return $ok->($request);
        }),
        route('/response' => sub ($request) {
            return json_response({ error => 'Concrete Response' }, status => 401)
                unless auth($request)->user->is_authenticated;
            return $ok->($request);
        }),
        route('/pages' => sub ($request) {
            return PAGI::Pages->status(401,
                detail => 'Sign in to view this page.',
                headers => ['WWW-Authenticate' => www_authenticate('Bearer', realm => 'demo')],
            )
                unless auth($request)->user->is_authenticated;
            return $ok->($request);
        }),
        route('/object' => sub ($request) {
            return AuthExtensions::NoticeApp->new($notice->($request))
                unless auth($request)->user->is_authenticated;
            return $ok->($request);
        }),
        route('/native' => sub ($request) {
            return as_app_object(async sub ($scope, $receive, $send) {
                await invoke_app($notice->($request), $scope, $receive, $send);
                return;
            }) unless auth($request)->user->is_authenticated;
            return $ok->($request);
        }),
        mount('/group', app => router(routes => [
            route('/' => sub ($request) { return $ok->($request) }),
        ]), middleware => [middleware($group)]),
    ],
);
