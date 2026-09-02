package MyApp::API;
use strict;
use warnings;
use Future::AsyncAwait;

use MyApp::API::User;
use PAGI::Pages qw(not_found unauthorized);
use PAGI::Request;
use PAGI::Response qw(html_response json_response);
use PAGI::Routing qw(middleware mount route router sse);
use PAGI::Routing::URL qw(path_for);
use PAGI::State qw(app_state);
use PAGI::Utils qw(invoke_app);

sub new {
    my ($class, %args) = @_;
    die "events is required\n" unless $args{events};
    die "users is required\n" unless $args{users};
    return bless {
        events => $args{events},
        users  => $args{users},
    }, $class;
}

sub Int { return qr/\A\d+\z/ }

sub routing {
    my ($self) = @_;

    return router(
        http_default => not_found(
            detail => 'No API endpoint route matched'),
        routes => [
            route('/index' => sub { return $self->index(@_) },
                name => 'index',
                middleware => [middleware(sub {
                    my ($inner) = @_;
                    return $self->require_demo_token($inner);
                })]),
            route('/show/{user_id:&Int}' =>
                MyApp::API::User->new(users => $self->{users}),
                name => 'show',
                middleware => [middleware(sub {
                    my ($inner) = @_;
                    return $self->require_demo_token($inner);
                })]),
            mount('/tools', routes => [
                route('/status' => sub { return $self->status(@_) },
                    name => 'status'),
            ], name => 'tools'),
            mount('/events', routes => [
                sse('/stream' => $self->{events}, name => 'stream'),
            ], name => 'events'),
        ],
    );
}

sub require_demo_token {
    my ($self, $inner) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $request = PAGI::Request->new($scope, $receive);

        return await $inner->($scope, $receive, $send)
            if ($request->header('x-demo-token') // '') eq 'demo-token';

        my $response = unauthorized(
            challenge => 'DemoToken realm="endpoint-class-demo"',
            detail    => 'demo token required');
        return await invoke_app($response, $scope, $receive, $send);
    };
}

async sub index {
    my ($self, $request) = @_;
    my $state = app_state($request)
        or die 'endpoint-class-demo requires Compose lifespan state';
    $state->get('metrics')->{requests}++;

    my $alice = path_for($request, 'show', { user_id => 1 });
    my $resource = $state->get('resource')->{name};
    return html_response(<<"HTML");
<!doctype html>
<title>Demo API</title>
<h1>Demo API</h1>
<p>Resource: $resource</p>
<p><a href="$alice">Alice</a></p>
HTML
}

async sub status {
    my ($self, $request) = @_;
    my $state = app_state($request)
        or die 'endpoint-class-demo requires Compose lifespan state';
    return json_response({
        status   => 'ready',
        resource => $state->get('resource')->{name},
    });
}

1;
