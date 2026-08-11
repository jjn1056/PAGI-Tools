#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Endpoint::Router ();
use PAGI::Test::Client ();
use PAGI::Compose qw(compose);

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
        my ($self, $c) = @_;
        push @Local::BindingEndpoint::calls,
            ['role', Scalar::Util::refaddr($self), scalar @_];
        return $c->text('role');
    }
}

{
    package Local::BindingBase;
    use parent 'PAGI::Endpoint::Router';
    sub inherited {
        my ($self, $c) = @_;
        push @Local::BindingEndpoint::calls,
            ['inherited', Scalar::Util::refaddr($self), scalar @_];
        return $c->text('inherited');
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
            return $_[0]->text('closure');
        });
        $r->websocket('/socket' => 'socket_handler');
        $r->sse('/events' => 'event_handler');
    }

    sub sync_handler {
        my ($self, $c) = @_;
        push @calls, ['sync', Scalar::Util::refaddr($self), scalar @_];
        return $c->text($self->{configured});
    }

    sub future_handler {
        my ($self, $c) = @_;
        push @calls, ['future', Scalar::Util::refaddr($self), scalar @_];
        return Future->done($c->text('future'));
    }

    sub socket_handler {
        my ($self, $c) = @_;
        push @calls, ['websocket', Scalar::Util::refaddr($self), scalar @_];
        return $c->close(1000, 'method');
    }

    sub event_handler {
        my ($self, $c) = @_;
        push @calls, ['sse', Scalar::Util::refaddr($self), scalar @_];
        $c->start->get;
        return $c->close;
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
        my ($self, $c) = @_;
        $self->{receiver} = Scalar::Util::refaddr($self);
        return $c->text($self->{label});
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

subtest 'the public surface is method-oriented and has no legacy machinery' => sub {
    for my $method (qw(new routes to_router to_app middleware_as app_as new_context)) {
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
        'method handlers receive exactly self and Context');
    is([map { $_->[1] } @Local::BindingEndpoint::calls[0 .. 3]],
        [($receiver) x 4], 'local, inherited, and aliased handlers share one receiver');
    is($Local::BindingEndpoint::coderef_arity, 1,
        'handler coderef receives only the ordinary Context argument');
    isa_ok($Local::BindingEndpoint::coderef_context, 'PAGI::Context::HTTP');

    my $ws = run_scope($app, scope(type => 'websocket', path => '/socket',
        raw_path => '/socket'));
    my $sse = run_scope($app, scope(type => 'sse', path => '/events',
        raw_path => '/events'));
    is($ws, [{ type => 'websocket.close', code => 1000, reason => 'method' }],
        'WebSocket method receives the shared compiler Context');
    is($sse, [{ type => 'sse.start', status => 200 },
              { type => 'sse.close' }],
        'SSE method receives the shared compiler Context');
    is([map { $_->[1] } @Local::BindingEndpoint::calls[-2, -1]],
        [$receiver, $receiver], 'protocol methods retain the same Endpoint receiver');
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
    sub new_context {
        my $self = shift;
        ++$self->{new_context_calls};
        return $self->SUPER::new_context(@_);
    }
    sub routes {
        my ($self, $r) = @_;
        $r->get('/context' => sub {
            $self->{compiled_context} = ref($_[0]);
            return $_[0]->text('context');
        });
        $r->get('/state' => sub {
            my ($c) = @_;
            $self->{scope_has_state} = exists $c->scope->{state} ? 1 : 0;
            $self->{request_state} = $c->state;
            return $c->text('state');
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

subtest 'new_context is explicit and is not the compiler Context factory' => sub {
    my $endpoint = bless {}, 'Local::HelperEndpoint';
    my ($receive, $send) = channels();
    for my $case (
        [http => 'PAGI::Context::HTTP'],
        [websocket => 'PAGI::Context::WebSocket'],
        [sse => 'PAGI::Context::SSE'],
    ) {
        my ($type, $class) = @$case;
        my $context = $endpoint->new_context(scope(type => $type), $receive, $send);
        isa_ok($context, $class);
    }
    is($endpoint->{new_context_calls}, 3, 'override applies to explicit helper calls');

    PAGI::Test::Client->new(app => $endpoint->to_app)->get('/context');
    is($endpoint->{compiled_context}, 'PAGI::Context::HTTP',
        'compiled handler still receives the shared compiler Context');
    is($endpoint->{new_context_calls}, 3,
        'routing compilation and dispatch do not call the override');
};

subtest 'Endpoint seeds no state and Compose exposes server-owned lifespan state' => sub {
    my $endpoint = bless {}, 'Local::HelperEndpoint';
    my $plain_scope = scope(path => '/state', raw_path => '/state');
    run_scope($endpoint->to_app, $plain_scope);
    ok(!$endpoint->{scope_has_state}, 'Endpoint does not add state to a request scope');
    is($plain_scope->{state}, undef, 'the caller scope remains without state');
    is($endpoint->{request_state}, {}, 'Context supplies only its empty fallback');

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
    is($endpoint->{request_state}{server_value}, 'ready',
        'Context sees the server state populated through Compose lifespan');
    is(refaddr($endpoint->{request_state}), refaddr($state),
        'server-owned state identity is retained');
};

done_testing;
