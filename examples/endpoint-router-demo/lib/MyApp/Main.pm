package MyApp::Main;
use parent 'PAGI::Endpoint::Router';
use strict;
use warnings;
use Future::AsyncAwait;

use MyApp::API;
use PAGI::App::File;
use File::Spec;
use File::Basename qw(dirname);

async sub on_startup {
    my ($self) = @_;
    warn "MyApp starting up...\n";

    $self->stash->{config} = {
        app_name => 'Endpoint Router Demo',
        version  => '1.0.0',
    };

    $self->stash->{metrics} = {
        requests  => 0,
        ws_active => 0,
    };

    warn "MyApp ready!\n";
}

async sub on_shutdown {
    my ($self) = @_;
    warn "MyApp shutting down...\n";
}

sub routes {
    my ($self, $r) = @_;

    # Home page
    $r->get('/' => 'home');

    # API subrouter
    $r->mount('/api' => MyApp::API->to_app);

    # WebSocket echo
    $r->websocket('/ws/echo' => 'ws_echo');

    # SSE metrics
    $r->sse('/events/metrics' => 'sse_metrics');

    # Static files - find the root directory dynamically
    my $root = File::Spec->catdir(dirname(__FILE__), '..', '..', 'public');
    $r->mount('/' => PAGI::App::File->new(root => $root)->to_app);
}

async sub home {
    my ($self, $req, $res) = @_;
    my $config = $req->stash->{config};

    my $html = <<"HTML";
<!DOCTYPE html>
<html>
<head><title>$config->{app_name}</title></head>
<body>
<h1>$config->{app_name}</h1>
<p>Version: $config->{version}</p>
<ul>
<li><a href="/api/info">API Info</a></li>
<li><a href="/api/users">Users</a></li>
</ul>
</body>
</html>
HTML

    await $res->html($html);
}

async sub ws_echo {
    my ($self, $ws) = @_;

    await $ws->accept;
    $ws->start_heartbeat(25);

    my $metrics = $ws->stash->{metrics};
    $metrics->{ws_active}++;

    $ws->on_close(sub {
        $metrics->{ws_active}--;
    });

    await $ws->send_json({ type => 'connected' });

    await $ws->each_json(async sub {
        my ($data) = @_;
        await $ws->send_json({ type => 'echo', data => $data });
    });
}

async sub sse_metrics {
    my ($self, $sse) = @_;

    my $metrics = $sse->stash->{metrics};

    await $sse->send_event('connected', { status => 'ok' });

    await $sse->every(2, async sub {
        $metrics->{requests}++;
        await $sse->send_event('metrics', $metrics);
    });
}

1;
