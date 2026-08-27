#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Endpoint::Router ();
use PAGI::Test::Client ();

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
    package Local::ReverseChildEndpoint;
    use parent 'PAGI::Endpoint::Router';

    sub new { return bless { seen => [] }, $_[0] }

    sub routes {
        my ($self, $r) = @_;
        $r->get('/item/{id}' => 'show')->name('show');
    }

    sub show {
        my ($self, $c) = @_;
        my $params = { %{$c->scope->{path_params}} };
        if (!exists $params->{tenant}) {
            ++$self->{opaque_calls};
            return $c->text('opaque child');
        }
        my $record = {
            receiver => Scalar::Util::refaddr($self),
            params => $params,
            relative => $c->path_for('show'),
            left => $c->path_for('/left/show', $params),
            right => $c->path_for('/right/show', $params),
        };
        push @{$self->{seen}}, $record;
        return $c->text($record->{relative});
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
        'relative Context lookup selects the active left placement');
    is($client->get('/right/beta/item/2')->text, '/right/beta/item/2',
        'relative Context lookup selects the active right placement');
    is([map { $_->{receiver} } @{$child->{seen}}], [$identity, $identity],
        'both explicit child snapshots retain the Endpoint object identity');
    is([map { [$_->{left}, $_->{right}] } @{$child->{seen}}], [
        ['/left/acme/item/1', '/right/acme/item/1'],
        ['/left/beta/item/2', '/right/beta/item/2'],
    ], 'absolute Context lookup can select either sibling placement');

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

    sub known { return $_[1]->text('known') }

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

done_testing;
