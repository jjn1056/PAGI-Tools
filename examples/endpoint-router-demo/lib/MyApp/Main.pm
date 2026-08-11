package MyApp::Main;
use parent 'PAGI::Endpoint::Router';
use strict;
use warnings;
use Future::AsyncAwait;

use MyApp::API;
use PAGI::App::File;
use File::Basename qw(dirname);
use File::Spec;

sub new {
    my ($class, %args) = @_;
    die "api is required\n" unless $args{api};
    return bless { api => $args{api} }, $class;
}

sub routes {
    my ($self, $r) = @_;

    $r->get('/' => 'home')->name('home');
    $r->mount('/api', router => $self->{api})->name('api');
    $r->websocket('/status' => 'status_socket')->name('status_socket');

    my $root = File::Spec->catdir(dirname(__FILE__), '..', '..', 'public');
    $r->mount('/', PAGI::App::File->new(root => $root));
}

async sub home {
    my ($self, $c) = @_;
    $c->state->{metrics}{requests}++;

    my $api_index = $c->path_for('/api/index');
    return $c->html(<<"HTML");
<!doctype html>
<title>Endpoint Router Demo</title>
<h1>Endpoint Router Demo</h1>
<p>The root Endpoint owns this page, static files, and the status WebSocket.</p>
<p><a href="$api_index">API index</a></p>
HTML
}

async sub status_socket {
    my ($self, $c) = @_;
    await $c->accept;

    my $state = $c->state;
    await $c->send_json({
        type     => 'ready',
        resource => $state->{resource}{name},
    });

    await $c->each_json(async sub {
        my ($message) = @_;
        $state->{metrics}{websocket_messages}++;
        await $c->send_json({ type => 'echo', data => $message });
    });
}

1;
