package MyApp::Main;
use strict;
use warnings;
use Future::AsyncAwait;

use MyApp::StatusSocket;
use PAGI::App::File;
use PAGI::Response qw(html_response);
use PAGI::Routing qw(mount route websocket);
use PAGI::Routing::URL qw(path_for);
use PAGI::State qw(app_state);
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
        websocket('/status' => MyApp::StatusSocket->new,
            name => 'status_socket'),
        mount('/', app => PAGI::App::File->new(root => $self->public_root)),
    ];
}

async sub home {
    my ($self, $request) = @_;
    my $state = app_state($request)
        or die 'endpoint-class-demo requires Compose lifespan state';
    $state->get('metrics')->{requests}++;

    my $api_index = path_for($request, '/api/index');
    return html_response(<<"HTML");
<!doctype html>
<title>Endpoint Class Demo</title>
<h1>Endpoint Class Demo</h1>
<p>The root assembler owns this page, static files, and the status WebSocket.</p>
<p><a href="$api_index">API index</a></p>
HTML
}

1;
