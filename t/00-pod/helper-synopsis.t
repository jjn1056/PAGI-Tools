use strict;
use warnings;
use Test2::V0;
use FindBin;

use PAGI::Test::Client;
use Future;
use lib "$FindBin::Bin/../lib";
use PAGITest::Connected qw(sse_scope);

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

    my $older = $client->websocket('/json?user=bob');
    my $newer = $client->websocket('/json?user=bob');
    $older->close;
    ok(exists $PAGITest::WebSocketSynopsis::online{bob},
        "an older connection closing does not remove the user's newer one");
    $newer->close;
    ok(!exists $PAGITest::WebSocketSynopsis::online{bob}, 'the newer one closing does');

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

    # An event published while the replay is still going out must neither be
    # lost nor overtake the replay. Drive the route with sends settled by hand.
    my @issued;
    my $send = sub {
        push @issued, { event => $_[0], future => Future->new };
        return $issued[-1]{future};
    };
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $disconnect = Future->new;
    my $handler = $app->to_app->(
        sse_scope(path => '/events'), sub { $disconnect }, $send,
    );
    $issued[0]{future}->done;    # let the first send through
    PAGITest::SSESynopsis::publish(event => 'news', data => 'three');
    while (my ($pending) = grep { !$_->{future}->is_ready } @issued) {
        $pending->{future}->done;
    }
    is [map { $_->{event}{data} } grep { $_->{event}{type} eq 'sse.send' } @issued],
        ['one', 'two', 'three'],
        'an event published during the replay follows it';
    $disconnect->done({ type => 'sse.disconnect' });
    is \@warnings, [], 'and nothing complains';
};

done_testing;
