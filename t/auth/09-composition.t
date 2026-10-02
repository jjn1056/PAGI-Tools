use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Auth qw(auth auth_result unauth_result www_authenticate);
use PAGI::Auth::SimpleUser;
use PAGI::Compose qw(compose);
use PAGI::Response qw(response);
use PAGI::Routing qw(route mount middleware);
use PAGI::Test::Client;
use PAGI::Utils qw(invoke_app);
use PAGI::Utils::Middleware qw(clone_scope);

# The cookbook's application-owned HTTP policy, with a call log supplied by
# the test. The bypass must precede auth(), including at Compose root.
sub require_login {
    my ($next, %config) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        return await $next->($scope, $receive, $send)
            unless ($scope->{type} // '') eq 'http';
        push @{$config{calls}}, 'http';
        my $context = auth($scope);
        unless ($context->user->is_authenticated) {
            my $failure = $context->failure;
            my $malformed = $failure
                && ($failure->code // '') eq 'malformed_authorization';
            my @params = (realm => 'api');
            push @params, error => ($malformed ? 'invalid_request' : 'invalid_token')
                if $failure;
            await invoke_app(response('JSON',
                { error => $malformed ? 'Malformed Authorization header.'
                    : 'Please sign in to access this API.' },
                status => $malformed ? 400 : 401,
                headers => ['WWW-Authenticate' => www_authenticate('Bearer', @params)],
            ), $scope, $receive, $send);
            return;
        }
        await $next->($scope, $receive, $send);
        return;
    };
}

{
    package Local::RequireLogin;
    sub new { my ($class, %config) = @_; return bless \%config, $class }
    sub wrap { my ($self, $next) = @_; return main::require_login($next, %$self) }
}
BEGIN { $INC{'Local/RequireLogin.pm'} = __FILE__ }

subtest 'factory, object, and class policies protect groups and bypass lifespan' => sub {
    for my $form (qw(factory object class)) {
        subtest $form => sub {
            my (@backend_calls, @policy_calls, @lifecycle);
            my $policy = $form eq 'factory'
                ? middleware(\&require_login, calls => \@policy_calls)
                : $form eq 'object'
                ? middleware(Local::RequireLogin->new(calls => \@policy_calls))
                : middleware('+Local::RequireLogin', calls => \@policy_calls);
            my $protected = compose(
                middleware => [
                    middleware('Authentication', backend => sub {
                        my ($request) = @_;
                        push @backend_calls, $request->scope->{type};
                        my $credential = $request->header('authorization') // '';
                        return auth_result(user => PAGI::Auth::SimpleUser->new(identity => 'alice'))
                            if $credential eq 'Bearer accepted';
                        return unauth_result(scopes => ['notes:read'])
                            if $credential eq 'Bearer guest';
                        return unauth_result(failure => {
                            message => 'Malformed header', code => 'malformed_authorization',
                        }) if $credential eq 'Malformed';
                        return unauth_result(failure => { message => 'Rejected', code => 'bad_token' })
                            if length $credential;
                        return unauth_result();
                    }),
                    $policy,
                ],
                routes => [
                    route('/me' => sub {
                        return response('JSON', { user_id => auth($_[0])->user->identity });
                    }),
                    route('/catalog' => async sub { return response('JSON', { items => [] }) }),
                ],
                lifespan => {
                    startup => sub { push @lifecycle, 'startup'; return },
                    shutdown => sub { push @lifecycle, 'shutdown'; return },
                },
            );
            # Exercise the cookbook at a lifecycle root as well as under mount.
            my $root_client = PAGI::Test::Client->new(app => $protected, lifespan => 1);
            $root_client->start;
            is \@backend_calls, [], 'startup does not authenticate';
            is \@policy_calls, [], 'startup does not inspect auth';
            is $root_client->get('/me', headers => { Authorization => 'Bearer accepted' })->status,
                200, 'HTTP at the lifecycle root authenticates';
            $root_client->stop;
            is \@lifecycle, [qw(startup shutdown)], 'both callbacks execute';
            is \@backend_calls, ['http'], 'shutdown does not authenticate';
            is \@policy_calls, ['http'], 'shutdown does not inspect auth';

            my $client = PAGI::Test::Client->new(app => compose(routes => [
                mount('/private', app => $protected),
                route('/public' => sub { response('JSON', { public => 1 }) }),
            ]));
            for my $path (qw(/me /catalog)) {
                my $accepted = $client->get('/private' . $path,
                    headers => { Authorization => 'Bearer accepted' });
                is $accepted->status, 200, "$path accepts a true user with no grants";
                is $accepted->json, $path eq '/me' ? { user_id => 'alice' } : { items => [] },
                    "$path selected response is unchanged";
                for my $case (
                    ['', 401, 'Bearer realm="api"'],
                    ['Bearer rejected', 401, 'Bearer realm="api", error="invalid_token"'],
                    ['Bearer guest', 401, 'Bearer realm="api"'],
                    ['Malformed', 400, 'Bearer realm="api", error="invalid_request"'],
                ) {
                    my ($credential, $status, $challenge) = @$case;
                    my $response = $client->get('/private' . $path,
                        headers => length($credential) ? { Authorization => $credential } : {});
                    is $response->status, $status, "$path policy handles '$credential'";
                    is $response->header('WWW-Authenticate'), $challenge,
                        'application chooses the challenge';
                }
            }
            my $before = scalar @backend_calls;
            is $client->get('/public')->json, { public => 1 }, 'public route remains accessible';
            is scalar(@backend_calls), $before, 'public route is outside authentication group';
            is scalar(@policy_calls), $before, 'every authenticated invocation reaches policy';
        };
    }
};

sub context_values {
    my ($source) = @_;
    my $context = auth($source);
    return [
        $context->user->identity,
        [@{$context->credentials->scopes}],
        $context->failure ? $context->failure->code : undef,
    ];
}

subtest 'nested authentication replaces all context fields and preserves outer observations' => sub {
    my (@outer, @inner);
    my $observe = sub {
        my ($next, %config) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            push @{$config{seen}}, context_values($scope);
            await $next->($scope, $receive, $send);
            push @{$config{seen}}, context_values($scope);
            return;
        };
    };
    my $child = compose(
        middleware => [
            middleware('Authentication', backend => sub {
                return auth_result(user => PAGI::Auth::SimpleUser->new(identity => 'inner'),
                    scopes => ['inner:write']);
            }),
            middleware($observe, seen => \@inner),
        ],
        routes => [route('/' => sub { response('JSON', context_values($_[0])) })],
    );
    my $client = PAGI::Test::Client->new(app => compose(
        middleware => [
            middleware('Authentication', backend => sub {
                return unauth_result(scopes => ['outer:read'],
                    failure => { message => 'Outer rejected', code => 'outer_rejected' });
            }),
            middleware($observe, seen => \@outer),
        ],
        routes => [mount('/inner', app => $child)],
    ));
    is $client->get('/inner/')->json, ['inner', ['inner:write'], undef],
        'Request sees complete replacement without outer grants or failure';
    is \@inner, [(['inner', ['inner:write'], undef]) x 2],
        'inner middleware sees its context before and after delegation';
    is \@outer, [(['', ['outer:read'], 'outer_rejected']) x 2],
        'outer observer still sees its guest, grants, and rejection';
};

subtest 'custom native installation uses the same context and guest continuation' => sub {
    my $custom = sub {
        my ($next) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            return await $next->($scope, $receive, $send)
                unless ($scope->{type} // '') eq 'http';
            my $result = unauth_result(scopes => ['notes:read']);
            my $inner = clone_scope($scope, { 'pagi.auth' => $result });
            await $next->($inner, $receive, $send);
            return;
        };
    };
    my $client = PAGI::Test::Client->new(app => compose(
        middleware => [middleware($custom)],
        routes => [route('/notes' => sub {
            my ($request) = @_;
            return response('JSON', {
                authenticated => auth($request)->user->is_authenticated ? 1 : 0,
                can_read => auth($request)->credentials->has('notes:read') ? 1 : 0,
                failed => auth($request)->failure ? 1 : 0,
            });
        })],
    ), lifespan => 1);
    $client->start;
    is $client->get('/notes')->json, { authenticated => 0, can_read => 1, failed => 0 },
        'omitting protection lets a granted guest reach the Request handler';
    $client->stop;
};

done_testing;
