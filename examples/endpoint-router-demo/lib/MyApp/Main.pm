package MyApp::Main;
use parent 'PAGI::Endpoint::Router';
use strict;
use warnings;
use Future::AsyncAwait;

use MyApp::API;
use PAGI::App::File;
use PAGI::Response qw(html_response);
use PAGI::Routing::URL qw(path_for);
use PAGI::State qw(app_state);

sub new {
    my ($class, %args) = @_;
    die "api is required\n" unless $args{api};
    return bless { api => $args{api} }, $class;
}

sub routes {
    my ($self, $r) = @_;

    $r->get('/' => 'home')->name('home');
    $r->mount('/api', app => $self->{api}->to_router)->name('api');
    $r->websocket('/status' => 'status_socket')->name('status_socket');

    $r->mount('/', app => PAGI::App::File->from_app_path('public'));
}

async sub home {
    my ($self, $request) = @_;
    my $state = app_state($request)
        or die 'endpoint-router-demo requires Compose lifespan state';
    $state->get('metrics')->{requests}++;

    my $api_index = path_for($request, '/api/index');
    return html_response(<<"HTML");
<!doctype html>
<title>Endpoint Router Demo</title>
<h1>Endpoint Router Demo</h1>
<p>The root Endpoint owns this page, static files, and the status WebSocket.</p>
<p><a href="$api_index">API index</a></p>
HTML
}

async sub status_socket {
    my ($self, $websocket) = @_;
    await $websocket->accept;

    my $state = app_state($websocket)
        or die 'endpoint-router-demo requires Compose lifespan state';
    await $websocket->send_json({
        type     => 'ready',
        resource => $state->get('resource')->{name},
    });

    await $websocket->each_json(async sub {
        my ($message) = @_;
        $state->get('metrics')->{websocket_messages}++;
        await $websocket->send_json({ type => 'echo', data => $message });
    });
}

1;
