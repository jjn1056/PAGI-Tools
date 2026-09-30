use strict;
use warnings;
use Test2::V0;
use FindBin;

use PAGI::Test::Client;

no warnings 'once';    # the SYNOPSIS variables are read from their packages

# The SYNOPSIS of PAGI::WebSocket and PAGI::SSE is the first code most
# people copy. Run each exactly as published: its indented verbatim
# paragraphs, joined in order, must build $app.

sub synopsis_app {
    my ($module, $package) = @_;
    my $pod = do {
        open my $fh, '<', "$FindBin::Bin/../../lib/PAGI/$module.pm" or die "$module: $!";
        local $/;
        <$fh>;
    };
    my ($section) = $pod =~ /^=head1 SYNOPSIS\n(.*?)^=head1 /ms;
    my $code = join "\n",
        grep { /\S/ }
        map  { my $p = $_; $p =~ s/^    //mg; $p }
        grep { /\A[ \t]/ } split /\n{2,}/, ($section // '') =~ s/\A\n+//r;
    my $app = eval "package $package; $code; \$app";
    is $@, '', "the PAGI::$module SYNOPSIS compiles and runs as published";
    return $app;
}

subtest 'PAGI::WebSocket' => sub {
    my $app = synopsis_app('WebSocket', 'PAGITest::WebSocketSynopsis') or return;
    my $client = PAGI::Test::Client->new(app => $app);

    $client->websocket('/echo', sub {
        my ($ws) = @_;
        $ws->send_text('hi');
        is $ws->receive_text, 'Echo: hi', '/echo echoes text';
    });

    $client->websocket('/json?user=ada', sub {
        my ($ws) = @_;
        is \%PAGITest::WebSocketSynopsis::online, { ada => D() },
            'the connection is registered while open';
        $ws->send_json({ type => 'ping' });
        is $ws->receive_json, { type => 'pong' }, '/json answers ping with pong';
    });
    is \%PAGITest::WebSocketSynopsis::online, {}, 'and removed when it closes';

    $client->websocket('/callbacks', sub {
        my ($ws) = @_;
        $ws->send_text('hi');
        is $ws->receive_text, 'Echo: hi', 'the callback style echoes too';
    });
};

subtest 'PAGI::SSE' => sub {
    my $app = synopsis_app('SSE', 'PAGITest::SSESynopsis') or return;
    my $client = PAGI::Test::Client->new(app => $app);

    PAGITest::SSESynopsis::publish(event => 'news', data => 'one');
    PAGITest::SSESynopsis::publish(event => 'news', data => 'two');

    $client->sse('/events', sub {
        my ($sse) = @_;
        is [map { $sse->receive_event->{data} } 1 .. 2], ['one', 'two'],
            'a new client receives the history';
    });
    is \%PAGITest::SSESynopsis::subscribers, {}, 'and is unsubscribed when it leaves';

    $client->sse('/events', headers => { 'Last-Event-ID' => '1' }, sub {
        my ($sse) = @_;
        my $event = $sse->receive_event;
        is [$event->{id}, $event->{data}], [2, 'two'],
            'a reconnecting client receives only what it missed';
    });
};

done_testing;
