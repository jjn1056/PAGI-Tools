package MyApp::API;
use strict;
use warnings;
use Future::AsyncAwait;

use PAGI::HTTPConnection;
use PAGI::Pages qw(not_found unauthorized);
use PAGI::Response qw(response);
use PAGI::Routing qw(endpoint middleware mount route router sse);
use PAGI::Routing::URL qw(path_for);
use PAGI::Utils qw(invoke_app);

sub new {
    my ($class, %args) = @_;
    die "users is required\n" unless $args{users};
    return bless { users => $args{users} }, $class;
}

sub Int { return qr/\A\d+\z/ }

sub routing {
    my ($self) = @_;

    my $demo_token_middleware = middleware(sub {
        my ($inner) = @_;
        return $self->require_demo_token($inner);
    });

    return router(
        http_default => not_found(
            detail => 'No API endpoint route matched'),
        routes => [
            route('/index' => sub { return $self->index(@_) },
                name => 'index',
                middleware => [$demo_token_middleware]),
            route('/show/{user_id:&Int}' =>
                endpoint('MyApp::API::User', users => $self->{users}),
                name => 'show',
                middleware => [$demo_token_middleware]),
            mount('/tools', routes => [
                route('/status' => sub { return $self->status(@_) },
                    name => 'status'),
            ], name => 'tools'),
            mount('/events', routes => [
                sse('/stream' => endpoint('MyApp::API::Events'), name => 'stream'),
            ], name => 'events'),
        ],
    );
}

sub require_demo_token {
    my ($self, $inner) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $token = PAGI::HTTPConnection->new($scope)->header('x-demo-token');

        return await $inner->($scope, $receive, $send)
            if ($token // '') eq 'demo-token';

        my $response = unauthorized(
            challenge => 'DemoToken realm="endpoint-class-demo"',
            detail    => 'demo token required');
        return await invoke_app($response, $scope, $receive, $send);
    };
}

async sub index {
    my ($self, $request) = @_;
    my $state = $request->state;
    $state->get('metrics')->{requests}++;

    my $alice = path_for($request, 'show', { user_id => 1 });
    my $resource = $state->get('resource')->{name};
    return response('HTML', <<"HTML");
<!doctype html>
<title>Demo API</title>
<h1>Demo API</h1>
<p>Resource: $resource</p>
<p><a href="$alice">Alice</a></p>
HTML
}

async sub status {
    my ($self, $request) = @_;
    my $state = $request->state;
    return response('JSON', {
        status   => 'ready',
        resource => $state->get('resource')->{name},
    });
}

1;
