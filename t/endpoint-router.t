#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use File::Spec;
use FindBin qw($Bin);
use Scalar::Util qw(refaddr);

use lib 'lib';
use lib "$Bin/lib";
use PAGI::Endpoint::Router ();
use PAGI::Response ();
use PAGI::Test::Client ();
use PAGI::Compose qw(compose);
use TestApps::AppPath::Endpoint ();

sub scope {
    my (%changes) = @_;
    return {
        type => 'http', method => 'GET', path => '/', raw_path => '/',
        root_path => '', path_params => {}, headers => [], %changes,
    };
}

sub channels {
    my @events;
    my $receive = sub { return Future->done({ type => 'unused.receive' }) };
    my $send = sub { push @events, $_[0]; return Future->done };
    return ($receive, $send, \@events);
}

sub run_scope {
    my ($app, $request_scope) = @_;
    my ($receive, $send, $events) = channels();
    $app->($request_scope, $receive, $send)->get;
    return $events;
}

{
    package Local::BindingRole;
    sub supplied {
        my ($self, $request) = @_;
        push @Local::BindingEndpoint::calls,
            ['role', Scalar::Util::refaddr($self), scalar @_, ref($request)];
        return PAGI::Response->text('role');
    }
}

{
    package Local::BindingBase;
    use parent 'PAGI::Endpoint::Router';
    sub inherited {
        my ($self, $request) = @_;
        push @Local::BindingEndpoint::calls,
            ['inherited', Scalar::Util::refaddr($self), scalar @_, ref($request)];
        return PAGI::Response->text('inherited');
    }
}

{
    package Local::BindingEndpoint;
    use parent -norequire, 'Local::BindingBase';
    our (@calls, $constructed, $coderef_arity, $coderef_context);
    no warnings 'once';
    *role_alias = \&Local::BindingRole::supplied;

    sub new {
        my ($class) = @_;
        ++$constructed;
        return bless { configured => 'class-instance' }, $class;
    }

    sub routes {
        my ($self, $r) = @_;
        $r->get('/sync' => 'sync_handler');
        $r->get('/future' => 'future_handler');
        $r->get('/inherited' => 'inherited');
        $r->get('/role' => 'role_alias');
        $r->get('/closure' => sub {
            $coderef_arity = scalar @_;
            $coderef_context = $_[0];
            return PAGI::Response->text('closure');
        });
        $r->websocket('/socket' => 'socket_handler');
        $r->sse('/events' => 'event_handler');
    }

    sub sync_handler {
        my ($self, $request) = @_;
        push @calls, ['sync', Scalar::Util::refaddr($self), scalar @_, ref($request)];
        return PAGI::Response->text($self->{configured});
    }

    sub future_handler {
        my ($self, $request) = @_;
        push @calls, ['future', Scalar::Util::refaddr($self), scalar @_, ref($request)];
        return Future->done(PAGI::Response->text('future'));
    }

    sub socket_handler {
        my ($self, $websocket) = @_;
        push @calls, [
            'websocket', Scalar::Util::refaddr($self), scalar @_, ref($websocket),
        ];
        return $websocket->close(1000, 'method');
    }

    sub event_handler {
        my ($self, $sse) = @_;
        push @calls, ['sse', Scalar::Util::refaddr($self), scalar @_, ref($sse)];
        $sse->start->get;
        return $sse->close;
    }
}

{
    package Local::ConfiguredEndpoint;
    use parent 'PAGI::Endpoint::Router';
    sub new {
        my ($class, %args) = @_;
        die "label is required\n" unless defined $args{label};
        return bless { label => $args{label} }, $class;
    }
    sub routes { $_[1]->get('/configured' => 'show') }
    sub show {
        my ($self, $request) = @_;
        $self->{receiver} = Scalar::Util::refaddr($self);
        return PAGI::Response->text($self->{label});
    }
}

{
    package Local::MissingHandler;
    use parent 'PAGI::Endpoint::Router';
    sub routes { $_[1]->get('/missing' => 'does_not_exist') }
}

{
    package Local::QualifiedHandler;
    use parent 'PAGI::Endpoint::Router';
    sub routes { $_[1]->get('/qualified' => 'Local::Other::handler') }
}

{
    package Local::BadResponse;
    use parent 'PAGI::Endpoint::Router';
    sub routes { $_[1]->get('/bad' => 'bad') }
    sub bad { return 'not a response' }
}

{
    package Local::CompositionEndpoint;
    use parent 'PAGI::Endpoint::Router';
    use PAGI::Routing qw(route);

    sub new {
        my ($class) = @_;
        return bless { receivers => [], native_calls => [] }, $class;
    }

    sub routes {
        my ($self, $r) = @_;
        $self->{root_facade} = $r;
        $r->http_default($self->app_as('not_found_app'));
        $r->get('/' => 'index')->name('index');
        $r->get('/closure' => sub {
            $self->{coderef_arity} = scalar @_;
            $self->{coderef_context} = $_[0];
            return PAGI::Response->text('closure');
        });
        $r->mount('/admin', routes => sub {
            my ($admin) = @_;
            $self->{admin_facade} = $admin;
            $admin->get('/users' => 'users')->name('users');
        })->name('admin');
        my $legacy = $self->app_as('legacy_app');
        $self->{legacy_app} = $legacy;
        $r->mount('/legacy', app => $legacy);
        my $array_routes = [
            route('/leaf' => sub {
                $self->{array_coderef_arity} = scalar @_;
                return PAGI::Response->text('array leaf');
            }, name => 'leaf'),
        ];
        $self->{array_routes} = $array_routes;
        $r->mount('/array', routes => $array_routes)->name('array');
    }

    sub index {
        my ($self, $request) = @_;
        push @{$self->{receivers}}, Scalar::Util::refaddr($self);
        return PAGI::Response->text('index');
    }

    sub users {
        my ($self, $request) = @_;
        push @{$self->{receivers}}, Scalar::Util::refaddr($self);
        return PAGI::Response->text('users');
    }

    sub _native_response {
        my ($self, $label, $arity, $scope, $receive, $send) = @_;
        push @{$self->{native_calls}}, [
            $label, Scalar::Util::refaddr($self), $arity,
            Scalar::Util::refaddr($scope), Scalar::Util::refaddr($receive),
            Scalar::Util::refaddr($send),
        ];
        return $send->({
            type => 'http.response.start', status => 200, headers => [],
        })->then(sub {
            return $send->({
                type => 'http.response.body', body => $label, more => 0,
            });
        });
    }

    sub not_found_app {
        my ($self, $scope, $receive, $send) = @_;
        return $self->_native_response(
            'endpoint default', scalar @_, $scope, $receive, $send,
        );
    }

    sub legacy_app {
        my ($self, $scope, $receive, $send) = @_;
        return $self->_native_response(
            'legacy app', scalar @_, $scope, $receive, $send,
        );
    }
}

{
    package Local::BadCompositionEndpoint;
    use parent 'PAGI::Endpoint::Router';
    sub new { return bless { mode => $_[1] }, $_[0] }
    sub native { return Future->done }
    sub routes {
        my ($self, $r) = @_;
        return $r->group('/bad', sub { }) if $self->{mode} eq 'group';
        return $r->mount('/bad', $self->app_as('native'))
            if $self->{mode} eq 'positional';
        return $r->mount('/bad', router => $self->app_as('native'))
            if $self->{mode} eq 'router';
        return $r->mount('/bad', app => 'native')
            if $self->{mode} eq 'mount-string';
        return $r->http_default('native')
            if $self->{mode} eq 'default-string';
        return $r->get('/bad', raw => 'native')
            if $self->{mode} eq 'raw-string';
    }
}

{
    package Local::CallbackContractEndpoint;
    use parent 'PAGI::Endpoint::Router';

    sub new { return bless { mode => $_[1], trace => [] }, $_[0] }

    sub routes {
        my ($self, $r) = @_;
        if ($self->{mode} eq 'normal') {
            push @{$self->{trace}}, 'before';
            my $future = Future->fail("callback return must stay ignored\n");
            $self->{callback_future} = $future;
            $r->mount('/callback', routes => sub {
                my ($child) = @_;
                push @{$self->{trace}}, 'callback';
                $child->get('/leaf' => 'leaf')->name('leaf');
                return $future;
            })->name('callback');
            push @{$self->{trace}}, 'after';
            return;
        }
        return $r->mount('/bad', routes => sub {
            die "callback explosion\n";
        }) if $self->{mode} eq 'throws';
        return $r->mount('/bad', routes => sub {
            ++$self->{malformed_callback_calls};
        }, 'dangling')
            if $self->{mode} eq 'odd';
        return $r->mount('/bad',
            routes => sub { ++$self->{malformed_callback_calls} },
            routes => sub { ++$self->{malformed_callback_calls} },
        ) if $self->{mode} eq 'duplicate';
        my $non_string = [];
        return $r->mount('/bad', $non_string => sub {
            ++$self->{malformed_callback_calls};
        });
    }

    sub leaf { return PAGI::Response->text('callback leaf') }
}

{
    package Local::InlinePathEndpoint;
    use parent 'PAGI::Endpoint::Router';

    sub resource_path {
        my ($self, @components) = @_;
        return $self->app_path(@components);
    }
}

subtest 'the public surface is method-oriented and has no legacy machinery' => sub {
    for my $method (qw(
        new routes to_router to_app middleware_as app_as new_request app_path
    )) {
        ok(PAGI::Endpoint::Router->can($method), "has $method");
    }
    for my $method (qw(state context_class _resolve_value_mw)) {
        ok(!PAGI::Endpoint::Router->can($method), "has no legacy $method");
    }

    my $base = PAGI::Endpoint::Router->new;
    isa_ok($base, 'PAGI::Endpoint::Router');
    is($base, {}, 'base new returns an empty instance');
    like(dies { PAGI::Endpoint::Router->new(unused => 1) },
        qr/new.*no (?:arguments|options)|accepts no/i,
        'base new rejects silently discarded configuration');
    isa_ok($base->to_router, 'PAGI::Routing::Router');
    is(ref($base->to_app), 'CODE', 'an empty Endpoint compiles to an app');
    my $missing = PAGI::Test::Client->new(app => $base->to_app)->get(
        '/missing', headers => { Accept => 'text/plain' },
    );
    is($missing->status, 404,
        'direct Endpoint to_app emits the Router stock HTTP NONE response');
    is($missing->header('Content-Type'), 'text/plain; charset=utf-8',
        'the stock HTTP NONE response negotiates its representation');
    is($missing->text,
        "404 Not Found\n\nThe requested resource was not found.\n",
        'the direct Router response contains the stock not-found document');
};

subtest 'the Endpoint facade follows the App Router composition grammar' => sub {
    my $endpoint = Local::CompositionEndpoint->new;
    my $identity = refaddr($endpoint);
    my $routing = $endpoint->to_router;

    isa_ok($endpoint->{root_facade}, 'PAGI::Endpoint::Router::Builder');
    isa_ok($endpoint->{admin_facade}, 'PAGI::Endpoint::Router::Builder');
    isnt(refaddr($endpoint->{root_facade}), refaddr($endpoint->{admin_facade}),
        'a routes callback receives a fresh Endpoint facade');
    isnt(refaddr($endpoint->{root_facade}{builder}),
        refaddr($endpoint->{admin_facade}{builder}),
        'the callback facade wraps a fresh child App Router');
    is(refaddr($endpoint->{root_facade}{endpoint}), $identity,
        'the root facade retains the Endpoint receiver');
    is(refaddr($endpoint->{admin_facade}{endpoint}), $identity,
        'the child facade retains the same Endpoint receiver');

    for my $method (qw(
        get post put patch delete head options any route websocket sse
        mount http_default name desc constraints
    )) {
        ok($endpoint->{root_facade}->can($method), "facade provides $method");
    }
    ok(!$endpoint->{root_facade}->can('group'), 'facade exposes no group');
    is([sort keys %{$routing->named_routes}],
        ['/admin/users', '/array/leaf', '/index'],
        'callback and arrayref routes remain discoverable through Mount names');
    my ($legacy_mount) = grep { $_->path eq '/legacy' } @{$routing->routes};
    is(refaddr($legacy_mount->app), refaddr($endpoint->{legacy_app}),
        'an app Mount value passes through unchanged');

    my $client = PAGI::Test::Client->new(app => $routing->to_app);
    is($client->get('/')->text, 'index', 'root method handler dispatches');
    is($client->get('/admin/users')->text, 'users',
        'callback method handler dispatches');
    is($endpoint->{receivers}, [$identity, $identity],
        'root and callback handler strings bind the same Endpoint instance');
    is($client->get('/closure')->text, 'closure',
        'an ordinary handler coderef dispatches');
    is($endpoint->{coderef_arity}, 1,
        'an ordinary handler coderef is not rebound to the Endpoint');
    isa_ok($endpoint->{coderef_context}, 'PAGI::Request');
    is($client->get('/legacy/anything')->text, 'legacy app',
        'app_as supplies an opaque Mount application');
    is($client->get('/missing')->text, 'endpoint default',
        'app_as supplies the Router HTTP default application');
    is($client->get('/array/leaf')->text, 'array leaf',
        'an arrayref routes value passes through to the App builder');
    is($endpoint->{array_coderef_arity}, 1,
        'an arrayref route coderef remains an ordinary Request handler');
    is([map { [$_->[0], $_->[1], $_->[2]] } @{$endpoint->{native_calls}}], [
        ['legacy app', $identity, 4],
        ['endpoint default', $identity, 4],
    ], 'native methods receive the same self plus exactly three PAGI channels');
};

subtest 'Endpoint native positions do not bind handler strings or old Mount forms' => sub {
    my @cases = (
        [group => qr/locate object method "group"/],
        [positional => qr/mount option list must be key\/value pairs|unknown mount option/],
        [router => qr/unknown mount option 'router'/],
        ['mount-string' => qr/mount app must be a coderef or instantiated object with to_app/],
        ['default-string' => qr/router http_default must be a coderef or instantiated object with to_app/],
        ['raw-string' => qr/raw application must be a coderef or instantiated object with to_app/],
    );
    for my $case (@cases) {
        my ($mode, $pattern) = @$case;
        like(dies { Local::BadCompositionEndpoint->new($mode)->to_router },
            $pattern, "$mode declaration is rejected without method magic");
    }
};

subtest 'Endpoint callback wrapping preserves synchronous App builder semantics' => sub {
    my $endpoint = Local::CallbackContractEndpoint->new('normal');
    my $routing = $endpoint->to_router;
    is($endpoint->{trace}, ['before', 'callback', 'after'],
        'the routes callback executes synchronously during declaration');
    isa_ok($endpoint->{callback_future}, 'Future');
    is($endpoint->{callback_future}->failure,
        "callback return must stay ignored\n",
        'a failed Future return remains unconsumed and is explicitly reported');
    is($routing->path_for('/callback/leaf'), '/callback/leaf',
        'the callback child declaration is retained instead of its return value');
    is(PAGI::Test::Client->new(app => $routing->to_app)
            ->get('/callback/leaf')->text,
        'callback leaf', 'the retained child handler remains Endpoint-bound');

    like(dies {
        Local::CallbackContractEndpoint->new('throws')->to_router;
    }, qr/callback explosion/,
        'a thrown callback error propagates during declaration');

    my @diagnostics = (
        [odd => qr/mount option list must be key\/value pairs/],
        [duplicate => qr/duplicate mount option 'routes'/],
        ['non-string' => qr/mount option names must be strings/],
    );
    for my $case (@diagnostics) {
        my ($mode, $pattern) = @$case;
        my $bad = Local::CallbackContractEndpoint->new($mode);
        like(dies { $bad->to_router }, $pattern,
            "$mode options retain the App builder diagnostic");
        is(0 + ($bad->{malformed_callback_calls} || 0), 0,
            "$mode options fail before a callback executes");
    }
};

subtest 'app_path delegates with the concrete Endpoint origin' => sub {
    local $ENV{PAGI_HOME};
    delete $ENV{PAGI_HOME};

    my $expected_home = File::Spec->canonpath(File::Spec->rel2abs($Bin));
    my $expected_static = File::Spec->canonpath(
        File::Spec->catfile($expected_home, 'static')
    );

    is(TestApps::AppPath::Endpoint->app_path(), $expected_home,
        'class helper resolves from the concrete t/lib module');
    is(TestApps::AppPath::Endpoint->new->app_path('static'), $expected_static,
        'object helper returns a platform-aware child path');
    unlike(TestApps::AppPath::Endpoint->app_path(),
        qr{PAGI.Tools\z},
        'inherited implementation does not resolve from the base distribution');

    my $inline = Local::InlinePathEndpoint->new;
    is($inline->resource_path('static'), $expected_static,
        'inline subclass falls back to the source of its method call');

    my $override = File::Spec->catdir($Bin, 'configured-home');
    local $ENV{PAGI_HOME} = $override;
    is($inline->resource_path('static'),
        File::Spec->canonpath(File::Spec->catfile(
            File::Spec->rel2abs($override), 'static')),
        'Endpoint helper honors the shared PAGI_HOME precedence');
    like(dies { $inline->resource_path(undef) },
        qr/app_path.*component 1.*relative/i,
        'Endpoint helper uses shared component validation');
};

subtest 'class compilation constructs once and binds exact method CODE values' => sub {
    @Local::BindingEndpoint::calls = ();
    $Local::BindingEndpoint::constructed = 0;
    my $app = Local::BindingEndpoint->to_app;
    is($Local::BindingEndpoint::constructed, 1,
        'one Endpoint instance is constructed for a class compilation');
    my $client = PAGI::Test::Client->new(app => $app);
    is($client->get('/sync')->text, 'class-instance', 'synchronous method response');
    is($client->get('/future')->text, 'future', 'Future method response');
    is($client->get('/inherited')->text, 'inherited', 'inherited method response');
    is($client->get('/role')->text, 'role', 'role-aliased method response');
    is($client->get('/closure')->text, 'closure', 'coderef response');

    my $receiver = $Local::BindingEndpoint::calls[0][1];
    is([map { [$_->[0], $_->[2]] } @Local::BindingEndpoint::calls[0 .. 3]],
        [['sync', 2], ['future', 2], ['inherited', 2], ['role', 2]],
        'method handlers receive exactly self and the protocol object');
    is([map { $_->[1] } @Local::BindingEndpoint::calls[0 .. 3]],
        [($receiver) x 4], 'local, inherited, and aliased handlers share one receiver');
    is([map { $_->[3] } @Local::BindingEndpoint::calls[0 .. 3]],
        [('PAGI::Request') x 4], 'HTTP methods receive direct Request objects');
    is($Local::BindingEndpoint::coderef_arity, 1,
        'handler coderef receives only the ordinary Request argument');
    isa_ok($Local::BindingEndpoint::coderef_context, 'PAGI::Request');

    my $ws = run_scope($app, scope(type => 'websocket', path => '/socket',
        raw_path => '/socket'));
    my $sse = run_scope($app, scope(type => 'sse', path => '/events',
        raw_path => '/events'));
    is($ws, [{ type => 'websocket.close', code => 1000, reason => 'method' }],
        'WebSocket method receives the shared compiler object');
    is($sse, [{ type => 'sse.start', status => 200 },
              { type => 'sse.close' }],
        'SSE method receives the shared compiler object');
    is([map { $_->[1] } @Local::BindingEndpoint::calls[-2, -1]],
        [$receiver, $receiver], 'protocol methods retain the same Endpoint receiver');
    is([map { $_->[3] } @Local::BindingEndpoint::calls[-2, -1]],
        ['PAGI::WebSocket', 'PAGI::SSE'],
        'protocol methods receive direct WebSocket and SSE objects');
};

subtest 'configured object calls retain object identity' => sub {
    my $endpoint = Local::ConfiguredEndpoint->new(label => 'kept object');
    my $identity = refaddr($endpoint);
    isa_ok($endpoint->to_router, 'PAGI::Routing::Router');
    my $response = PAGI::Test::Client->new(app => $endpoint->to_app)
        ->get('/configured');
    is($response->text, 'kept object', 'object configuration reaches its method');
    is($endpoint->{receiver}, $identity, 'object compilation preserves exact identity');
};

subtest 'handler validation is early and HTTP response validation stays shared' => sub {
    like(dies { Local::MissingHandler->to_router },
        qr/Local::MissingHandler has no handler method "does_not_exist"/,
        'missing handler fails while routes are materialized');
    like(dies { Local::QualifiedHandler->to_router },
        qr/handler method.*unqualified|unqualified.*handler method/i,
        'a qualified string is not a method-handler escape hatch');

    my $bad = Local::BadResponse->to_app;
    like(dies {
        run_scope($bad, scope(path => '/bad', raw_path => '/bad'));
    }, qr/handler did not return a response/,
        'shared HTTP adapter retains its response diagnostic');
};

{
    package Local::HelperBase;
    use parent 'PAGI::Endpoint::Router';
    sub inherited_factory {
        my ($self, $inner) = @_;
        return sub { $self->{inherited_seen}++; return $inner->(@_) };
    }
}

{
    package Local::HelperEndpoint;
    use parent -norequire, 'Local::HelperBase';
    no warnings 'once';
    *role_factory = sub {
        my ($self, $inner) = @_;
        return sub { $self->{role_seen}++; return $inner->(@_) };
    };
    sub native {
        my ($self, $scope, $receive, $send) = @_;
        $self->{native_arity} = scalar @_;
        return $send->({ type => 'native.event', marker => $scope->{marker} });
    }
    sub new_request {
        my $self = shift;
        ++$self->{new_request_calls};
        return $self->SUPER::new_request(@_);
    }
    sub routes {
        my ($self, $r) = @_;
        $r->get('/request' => sub {
            $self->{compiled_request} = ref($_[0]);
            return PAGI::Response->text('request');
        });
        $r->get('/state' => sub {
            my ($request) = @_;
            $self->{scope_has_state} = exists $request->scope->{state} ? 1 : 0;
            $self->{request_state} = $request->state;
            return PAGI::Response->text('state');
        });
    }
}

subtest 'middleware_as and app_as are validated normal closure adapters' => sub {
    my $endpoint = bless {}, 'Local::HelperEndpoint';
    my ($receive, $send, $events) = channels();
    my $factory = $endpoint->middleware_as('inherited_factory');
    my $role_factory = $endpoint->middleware_as('role_factory');
    my $native = $endpoint->app_as('native');
    is([$endpoint->{inherited_seen}, $endpoint->{role_seen}, scalar @$events],
        [undef, undef, 0], 'helper construction invokes no method and emits no events');

    my $inner = sub { return 'immediate downstream' };
    is($factory->($inner)->(scope(), $receive, $send), 'immediate downstream',
        'inherited middleware method wraps an immediate downstream result');
    is($role_factory->(sub { Future->done('future downstream') })
            ->(scope(), $receive, $send)->get,
        'future downstream', 'role-aliased middleware method preserves Future completion');

    $native->(scope(marker => 'exact channels'), $receive, $send)->get;
    is($events, [{ type => 'native.event', marker => 'exact channels' }],
        'app_as returns the native application closure');
    is($endpoint->{native_arity}, 4, 'native method receives self and three PAGI channels');

    for my $case (
        [middleware_as => 'missing'], [app_as => 'missing'],
        [middleware_as => 'Local::Other::factory'], [app_as => 'Other::app'],
    ) {
        my ($helper, $name) = @$case;
        like(dies { $endpoint->$helper($name) },
            qr/(?:has no (?:middleware|application) method|method name must be an unqualified name)/i,
            "$helper validates $name");
    }
};

subtest 'new_request is explicit and is not the compiler Request factory' => sub {
    my $endpoint = bless {}, 'Local::HelperEndpoint';
    my ($receive) = channels();
    ok(!$endpoint->can('new_context'), 'removed new_context has no compatibility alias');
    my $request = $endpoint->new_request(scope(type => 'http'), $receive);
    isa_ok($request, 'PAGI::Request');
    like(dies {
        $endpoint->new_request(scope(type => 'sse'), $receive);
    }, qr/HTTP scope/i, 'new_request rejects non-HTTP scopes');
    is($endpoint->{new_request_calls}, 2, 'override applies to explicit helper calls');

    PAGI::Test::Client->new(app => $endpoint->to_app)->get('/request');
    is($endpoint->{compiled_request}, 'PAGI::Request',
        'compiled handler receives the shared compiler Request');
    is($endpoint->{new_request_calls}, 2,
        'routing compilation and dispatch do not call the override');
};

subtest 'Endpoint seeds no state and Compose exposes server-owned lifespan state' => sub {
    my $endpoint = bless {}, 'Local::HelperEndpoint';
    my $plain_scope = scope(path => '/state', raw_path => '/state');
    run_scope($endpoint->to_app, $plain_scope);
    ok(!$endpoint->{scope_has_state}, 'Endpoint does not add state to a request scope');
    is($plain_scope->{state}, undef, 'the caller scope remains without state');
    is($endpoint->{request_state}, undef, 'Request reports absent state as undef');

    my $state = {};
    my $composed = compose(
        app => $endpoint->to_app,
        lifespan => { startup => sub { $_[0]{server_value} = 'ready' } },
    )->to_app;
    my @messages = ({ type => 'lifespan.startup' }, { type => 'lifespan.shutdown' });
    $composed->(
        scope(type => 'lifespan', state => $state),
        sub { return Future->done(shift @messages) },
        sub { return Future->done },
    )->get;
    run_scope($composed, scope(path => '/state', raw_path => '/state', state => $state));
    is($endpoint->{request_state}->get('server_value'), 'ready',
        'Request sees the server state populated through Compose lifespan');
    is(refaddr($endpoint->{request_state}->data), refaddr($state),
        'server-owned state identity is retained');
};

done_testing;
