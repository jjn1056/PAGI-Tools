#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Endpoint::Router ();
use PAGI::Response ();
use PAGI::Response::Text ();
use PAGI::Routing::URL ();
use PAGI::Test::Client ();
use PAGI::Utils qw(as_app);

sub scope {
    my (%changes) = @_;
    return {
        type => 'http', method => 'GET', path => '/', raw_path => '/',
        root_path => '', path_params => {}, headers => [], %changes,
    };
}

sub run_scope {
    my ($app, $request_scope) = @_;
    my @events;
    $app->(
        $request_scope,
        sub { return Future->done({ type => 'unused.receive' }) },
        sub { push @events, $_[0]; return Future->done },
    )->get;
    return \@events;
}

{
    package Local::DefaultApplicationEndpoint;
    use parent 'PAGI::Endpoint::Router';

    sub new {
        my ($class) = @_;
        return bless {
            response => PAGI::Response::Text->new('application default'),
        }, $class;
    }

    sub routes {
        my ($self, $r) = @_;
        $r->route('/application' => $self->{response});
    }
}

subtest 'Endpoint generic application object defaults to GET plus HEAD' => sub {
    my $endpoint = Local::DefaultApplicationEndpoint->new;
    my $routing;
    my $error = dies { $routing = $endpoint->to_router };

    is($error, undef,
        'Endpoint accepts a generic application object without explicit methods');
    return if defined $error;

    is($routing->routes->[0]->methods, ['GET', 'HEAD'],
        'Endpoint shares the immutable Route method fallback');

    my $client = PAGI::Test::Client->new(app => $routing->to_app);
    is($client->get('/application')->text, 'application default',
        'GET dispatches through the application endpoint');
    my $partial = $client->post('/application');
    is($partial->status, 405, 'Router owns the unsupported-method outcome');
    is($partial->header('allow'), 'GET, HEAD',
        'Router publishes the fallback method set in Allow');
};

{
    package Local::DefaultHandlerEndpoint;
    use parent 'PAGI::Endpoint::Router';

    sub new {
        my ($class) = @_;
        return bless {
            closure => sub {
                return PAGI::Response::Text->new('closure default');
            },
        }, $class;
    }

    sub routes {
        my ($self, $r) = @_;
        $r->route('/method-default' => 'method_default');
        $r->route('/closure-default' => $self->{closure});
    }

    sub method_default {
        return PAGI::Response::Text->new('method default');
    }
}

subtest 'Endpoint method-name and CODE routes share GET plus HEAD fallback' => sub {
    my $endpoint = Local::DefaultHandlerEndpoint->new;
    my $routing;
    my $error = dies { $routing = $endpoint->to_router };

    is($error, undef,
        'Endpoint generic handler declarations need no explicit methods');
    return if defined $error;

    is([map { $_->methods } @{$routing->routes}], [
        ['GET', 'HEAD'],
        ['GET', 'HEAD'],
    ], 'method-name and CODE handlers share immutable Route defaults');

    my $client = PAGI::Test::Client->new(app => $routing->to_app);
    is($client->get('/method-default')->text, 'method default',
        'the bound method handler dispatches through GET');
    is($client->get('/closure-default')->text, 'closure default',
        'the CODE handler dispatches through GET');

    for my $path (qw(/method-default /closure-default)) {
        my $partial = $client->post($path);
        is($partial->status, 405,
            "$path method mismatch is owned by Router");
        is($partial->header('allow'), 'GET, HEAD',
            "$path publishes the fallback method set in Allow");
    }
};

{
    package Local::RawEndpoint;
    use parent 'PAGI::Endpoint::Router';

    sub new {
        my ($class) = @_;
        my $self = bless { seen => [] }, $class;
        $self->{targets} = {
            http => PAGI::Utils::as_app(sub { return $self->_raw('http', @_) }),
            websocket => PAGI::Utils::as_app(sub { return $self->_raw('websocket', @_) }),
            sse => PAGI::Utils::as_app(sub { return $self->_raw('sse', @_) }),
        };
        $self->{closure} = sub {
            my ($request) = @_;
            return PAGI::Response::Text->new('closure');
        };
        return $self;
    }

    sub routes {
        my ($self, $r) = @_;
        for my $kind (qw(http websocket sse)) {
            my $method = $kind eq 'http' ? 'get' : $kind;
            $r->$method("/native-$kind/{id}" => [
                $self->middleware_as('mark_raw'),
            ], $self->{targets}{$kind});
        }
        $r->get('/method' => 'method_handler');
        $r->get('/closure' => $self->{closure});
    }

    sub mark_raw {
        my ($self, $inner) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            my $copy = { %$scope, endpoint_raw_middleware => 1 };
            return $inner->($copy, $receive, $send);
        };
    }

    sub _raw {
        my ($self, $kind, $scope, $receive, $send) = @_;
        push @{$self->{seen}}, {
            kind => $kind,
            type => $scope->{type},
            id => $scope->{path_params}{id},
            middleware => $scope->{endpoint_raw_middleware},
        };
        return $send->({
            type => 'http.response.start', status => 200, headers => [],
        })->then(sub {
            return $send->({
                type => 'http.response.body', body => 'raw http', more => 0,
            });
        }) if $kind eq 'http';
        return $send->({
            type => 'websocket.close', code => 1000, reason => 'raw websocket',
        }) if $kind eq 'websocket';
        return $send->({ type => 'sse.close' });
    }

    sub method_handler {
        my ($self, $request) = @_;
        return PAGI::Response::Text->new('method');
    }
}

{
    package Local::MalformedRawEndpoint;
    use parent 'PAGI::Endpoint::Router';
    sub new { return bless { mode => $_[1] }, $_[0] }
    sub routes {
        my ($self, $r) = @_;
        return $r->get('/bad', undef) if $self->{mode} eq 'undefined';
        return $r->websocket('/bad', 'native')
            if $self->{mode} eq 'noncoderef';
        return $r->sse('/bad', 'native') if $self->{mode} eq 'missing';
    }
}

subtest 'Endpoint application leaves preserve targets and middleware for every protocol' => sub {
    my $endpoint = Local::RawEndpoint->new;
    my $routing = $endpoint->to_router;
    my $nodes = $routing->routes;

    is([map { refaddr($nodes->[$_]->endpoint) } 0 .. 2],
        [map { refaddr($endpoint->{targets}{$_}) } qw(http websocket sse)],
        'Endpoint forwards every explicitly wrapped native app unchanged');
    is(refaddr($nodes->[4]->endpoint), refaddr($endpoint->{closure}),
        'an ordinary handler coderef remains unchanged');

    my $app = $routing->to_app;
    is(run_scope($app, scope(path => '/native-http/11', raw_path => '/native-http/11')), [
        { type => 'http.response.start', status => 200, headers => [] },
        { type => 'http.response.body', body => 'raw http', more => 0 },
    ], 'native HTTP application receives channels through Endpoint middleware');
    is(run_scope($app, scope(
        type => 'websocket', path => '/native-websocket/22',
        raw_path => '/native-websocket/22',
    )), [{
        type => 'websocket.close', code => 1000, reason => 'raw websocket',
    }], 'native WebSocket application receives channels through Endpoint middleware');
    is(run_scope($app, scope(
        type => 'sse', path => '/native-sse/33', raw_path => '/native-sse/33',
    )), [{ type => 'sse.close' }],
        'native SSE application receives channels through Endpoint middleware');
    is($endpoint->{seen}, [
        { kind => 'http', type => 'http', id => 11, middleware => 1 },
        { kind => 'websocket', type => 'websocket', id => 22, middleware => 1 },
        { kind => 'sse', type => 'sse', id => 33, middleware => 1 },
    ], 'each native application leaf sees captures and the middleware-cloned scope');

    my $client = PAGI::Test::Client->new(app => $app);
    is($client->get('/method')->text, 'method',
        'an ordinary method name keeps Endpoint binding semantics');
    is($client->get('/closure')->text, 'closure',
        'an ordinary handler coderef keeps Request binding semantics');
};

subtest 'Endpoint rejects malformed application leaf declarations through the App builder' => sub {
    like(dies { Local::MalformedRawEndpoint->new('undefined')->to_router },
        qr/route requires a target/,
        'an application leaf requires a defined target');
    like(dies { Local::MalformedRawEndpoint->new('noncoderef')->to_router },
        qr/has no handler method "native"/,
        'a package string is not rebound as an Endpoint method');
    like(dies { Local::MalformedRawEndpoint->new('missing')->to_router },
        qr/has no handler method "native"/,
        'a non-method string is rejected');
};

{
    package Local::ReverseChildEndpoint;
    use parent 'PAGI::Endpoint::Router';

    sub new { return bless { seen => [] }, $_[0] }

    sub routes {
        my ($self, $r) = @_;
        $r->get('/item/{id}' => 'show')->name('show');
    }

    sub show {
        my ($self, $request) = @_;
        my $params = { %{$request->scope->{path_params}} };
        if (!exists $params->{tenant}) {
            ++$self->{opaque_calls};
            return PAGI::Response::Text->new('opaque child');
        }
        my $record = {
            receiver => Scalar::Util::refaddr($self),
            params => $params,
            relative => PAGI::Routing::URL::path_for($request, 'show'),
            left => PAGI::Routing::URL::path_for(
                $request, '/left/show', $params,
            ),
            right => PAGI::Routing::URL::path_for(
                $request, '/right/show', $params,
            ),
        };
        push @{$self->{seen}}, $record;
        return PAGI::Response::Text->new($record->{relative});
    }
}

{
    package Local::ReverseParentEndpoint;
    use parent 'PAGI::Endpoint::Router';

    sub new { return bless { child => $_[1] }, $_[0] }

    sub routes {
        my ($self, $r) = @_;
        $r->mount('/left/{tenant}', app => $self->{child}->to_router)
            ->name('left');
        $r->mount('/right/{tenant}', app => $self->{child}->to_router)
            ->name('right');
        $r->mount('/opaque', app => $self->{child})->name('opaque');
    }
}

subtest 'explicit child snapshots expose each named Endpoint placement' => sub {
    my $child = Local::ReverseChildEndpoint->new;
    my $identity = refaddr($child);
    my $routing = Local::ReverseParentEndpoint->new($child)->to_router;

    is([sort keys %{$routing->named_routes}],
        ['/left/show', '/right/show'],
        'only explicit child Router applications publish nested names');
    is($routing->path_for('/left/show', { tenant => 'acme', id => 1 }),
        '/left/acme/item/1', 'absolute lookup selects the left placement');
    is($routing->path_for('/right/show', { tenant => 'beta', id => 2 }),
        '/right/beta/item/2', 'absolute lookup selects the right placement');

    my $client = PAGI::Test::Client->new(app => $routing->to_app);
    is($client->get('/left/acme/item/1')->text, '/left/acme/item/1',
        'relative Request lookup selects the active left placement');
    is($client->get('/right/beta/item/2')->text, '/right/beta/item/2',
        'relative Request lookup selects the active right placement');
    is([map { $_->{receiver} } @{$child->{seen}}], [$identity, $identity],
        'both explicit child snapshots retain the Endpoint object identity');
    is([map { [$_->{left}, $_->{right}] } @{$child->{seen}}], [
        ['/left/acme/item/1', '/right/acme/item/1'],
        ['/left/beta/item/2', '/right/beta/item/2'],
    ], 'absolute Request lookup can select either sibling placement');

    is($client->get('/opaque/item/3')->text, 'opaque child',
        'a direct Endpoint application remains dispatchable as opaque');
    is($child->{opaque_calls}, 1,
        'opaque dispatch still invokes the child Endpoint handler');
    like(dies {
        $routing->path_for('/opaque/show', { id => 3 });
    }, qr/unknown route|logical namespace/i,
        'the outer resolver does not guess names through an opaque Endpoint');
};

{
    package Local::BoundaryEndpoint;
    use parent 'PAGI::Endpoint::Router';

    sub new { return bless { default_calls => 0, default_seen => [] }, $_[0] }

    sub routes {
        my ($self, $r) = @_;
        my $default = $self->app_as('default_app');
        $self->{declared_default} = $default;
        $r->http_default($default);
        $r->get('/known' => 'known');
        $r->get('/throws' => 'throws');
    }

    sub known { return PAGI::Response::Text->new('known') }

    sub throws { die "selected endpoint explosion\n" }

    sub default_app {
        my ($self, $scope, $receive, $send) = @_;
        ++$self->{default_calls};
        push @{$self->{default_seen}}, {
            arity => scalar @_,
            type => $scope->{type},
            path => $scope->{path},
            scope => Scalar::Util::refaddr($scope),
            receive => Scalar::Util::refaddr($receive),
            send => Scalar::Util::refaddr($send),
        };
        return $send->({
            type => 'http.response.start', status => 418, headers => [],
        })->then(sub {
            return $send->({
                type => 'http.response.body', body => 'endpoint default', more => 0,
            });
        });
    }
}

{
    package Local::DuplicateDefaultEndpoint;
    use parent 'PAGI::Endpoint::Router';
    sub routes {
        my ($self, $r) = @_;
        $r->http_default(sub { return Future->done });
        $r->http_default(sub { return Future->done });
    }
}

subtest 'Endpoint http_default owns HTTP NONE and no other outcome' => sub {
    my $endpoint = Local::BoundaryEndpoint->new;
    my $routing = $endpoint->to_router;
    is(refaddr($routing->http_default), refaddr($endpoint->{declared_default}),
        'Endpoint forwards the original native default application unchanged');

    my $app = $routing->to_app;
    my $client = PAGI::Test::Client->new(app => $app);
    my $missing = $client->get('/missing');
    is([$missing->status, $missing->text], [418, 'endpoint default'],
        'custom Endpoint default responds to HTTP NONE');
    is($endpoint->{default_seen}[0]{arity}, 4,
        'app_as invokes the method with self plus three PAGI channels');
    is([@{$endpoint->{default_seen}[0]}{qw(type path)}],
        ['http', '/missing'], 'the default sees the unmatched HTTP scope');

    my $before = $endpoint->{default_calls};
    is($client->post('/known')->status, 405,
        'HTTP PARTIAL retains the shared method-not-allowed outcome');
    is($endpoint->{default_calls}, $before,
        'HTTP PARTIAL does not invoke the custom default');

    like(dies {
        run_scope($app, scope(path => '/throws', raw_path => '/throws'));
    }, qr/selected endpoint explosion/,
        'selected handler exceptions propagate');
    is($endpoint->{default_calls}, $before,
        'selected exceptions do not invoke the custom default');

    my $websocket = run_scope($app, scope(
        type => 'websocket', method => undef,
        path => '/missing', raw_path => '/missing',
    ));
    is($websocket, [{ type => 'websocket.close' }],
        'WebSocket NONE retains its protocol close');
    my $sse = run_scope($app, scope(
        type => 'sse', method => undef,
        path => '/missing', raw_path => '/missing',
    ));
    is($sse->[0]{type}, 'sse.http.response.start',
        'SSE NONE retains its protocol response family');
    is($endpoint->{default_calls}, $before,
        'WebSocket and SSE misses never invoke the HTTP default');

    like(dies { Local::DuplicateDefaultEndpoint->to_router },
        qr/http_default.*only.*once|already configured/i,
        'duplicate Endpoint defaults croak through the App builder');
};

{
    package Local::ProviderChildEndpoint;
    use parent 'PAGI::Endpoint::Router';
    sub routes { $_[1]->get('/leaf' => 'leaf')->name('leaf') }
    sub leaf {
        my ($self, $request) = @_;
        return PAGI::Response::Text->new('mount ' . $request->path_param('mount'));
    }
}

{
    package Local::ProviderEndpoint;
    use parent 'PAGI::Endpoint::Router';
    sub Int { return qr/\A\d+\z/ }
    sub new {
        my ($class, %args) = @_;
        return bless {
            mode => $args{mode}, child => Local::ProviderChildEndpoint->new,
        }, $class;
    }
    sub routes {
        my ($self, $r) = @_;
        if ($self->{mode} eq 'leaf') {
            $r->get('/provider/{leaf:&Int}' => 'provider_leaf')->name('leaf');
        }
        elsif ($self->{mode} eq 'callback') {
            $r->mount('/callback/{group:&Int}', routes => sub {
                $_[0]->get('/leaf' => 'callback_leaf')->name('leaf');
            })->name('callback');
        }
        else {
            $r->mount('/mount/{mount:&Int}', app => $self->{child}->to_router)
                ->name('mount');
        }
    }
    sub callback_leaf {
        my ($self, $request) = @_;
        return PAGI::Response::Text->new('callback ' . $request->path_param('group'));
    }
    sub provider_leaf {
        my ($self, $request) = @_;
        return PAGI::Response::Text->new('leaf ' . $request->path_param('leaf'));
    }
}

subtest 'leaf constraints resolve inline providers in the Endpoint package' => sub {
    my $client = PAGI::Test::Client->new(
        app => Local::ProviderEndpoint->new(mode => 'leaf')->to_app,
    );
    is($client->get('/provider/56')->text, 'leaf 56',
        'an unqualified leaf provider resolves in the Endpoint package');
    is($client->get('/provider/no')->status, 404,
        'the Endpoint leaf provider rejects a nonmatching capture');
};

subtest 'callback Mount constraints retain the Endpoint declaration package' => sub {
    my $client = PAGI::Test::Client->new(
        app => Local::ProviderEndpoint->new(mode => 'callback')->to_app,
    );
    is($client->get('/callback/12/leaf')->text, 'callback 12',
        'a callback Mount prefix resolves its provider in the Endpoint package');
    is($client->get('/callback/no/leaf')->status, 404,
        'the callback Mount provider rejects a nonmatching capture');
};

subtest 'explicit child Mount constraints retain the Endpoint declaration package' => sub {
    my $client = PAGI::Test::Client->new(
        app => Local::ProviderEndpoint->new(mode => 'mount')->to_app,
    );
    is($client->get('/mount/34/leaf')->text, 'mount 34',
        'an explicit child Mount prefix resolves its Endpoint provider');
    is($client->get('/mount/no/leaf')->status, 404,
        'the explicit child Mount provider rejects a nonmatching capture');
};

done_testing;
