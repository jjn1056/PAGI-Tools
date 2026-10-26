package MyApp::Main;
use strict;
use warnings;
use Future::AsyncAwait;

use PAGI::App::File;
use PAGI::Response qw(response);
use PAGI::Routing qw(endpoint mount route websocket);
use PAGI::Routing::URL qw(path_for);
use PAGI::Utils qw(app_path);

sub new {
    my ($class, %args) = @_;
    die "api is required\n" unless $args{api};
    return bless { api => $args{api} }, $class;
}

sub public_root {
    return app_path('public');
}

sub routes {
    my ($self) = @_;

    return [
        route('/' => sub { return $self->home(@_) }, name => 'home'),
        mount('/api', app => $self->{api}->routing, name => 'api'),
        websocket('/status' => endpoint('MyApp::StatusSocket'),
            name => 'status_socket'),
        # HTTP-only catch-all: WebSocket and SSE misses get the Router's
        # refusal instead of reaching the file application.
        route('/*path' => PAGI::App::File->new(root => $self->public_root)),
    ];
}

async sub home {
    my ($self, $request) = @_;
    my $state = $request->state;
    $state->get('metrics')->{requests}++;

    my $api_index = path_for($request, '/api/index');
    return response('HTML', <<"HTML");
<!doctype html>
<title>Endpoint Class Demo</title>
<h1>Endpoint Class Demo</h1>
<p>The root assembler owns this page, static files, and the status WebSocket.</p>
<p><a href="$api_index">API index</a></p>
HTML
}

1;
