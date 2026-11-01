use strict;
use warnings;
use Test2::V0;
use FindBin;

use PAGI::Test::Client;
use Future;
use lib "$FindBin::Bin/../lib";
use PAGITest::Connected qw(sse_scope);
use PAGITest::LeavingClient qw(leaves_at_handshake);

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
    my $scope = sse_scope(path => '/events');
    my $handler = $app->to_app->($scope, sub { $disconnect }, $send);
    $issued[0]{future}->done;    # let the first send through
    PAGITest::SSESynopsis::publish(event => 'news', data => 'three');
    while (my ($pending) = grep { !$_->{future}->is_ready } @issued) {
        $pending->{future}->done;
    }
    is [map { $_->{event}{data} } grep { $_->{event}{type} eq 'sse.send' } @issued],
        ['one', 'two', 'three'],
        'an event published during the replay follows it';
    # The client goes away: as a server does, end the connection, then deliver
    # the event. Left open, the handler would still be suspended at exit.
    $scope->{'pagi.connection'}->_mark_disconnected('client_closed');
    $disconnect->done({ type => 'sse.disconnect' });
    ok $handler->is_done, 'the stream ends when the client goes away';
    is \@warnings, [], 'and nothing complains';
};

subtest 'PAGI::ContentNegotiation' => sub {
    my $app = synopsis_app('ContentNegotiation', 'PAGITest::NegotiationSynopsis') or return;
    my $client = PAGI::Test::Client->new(app => $app);
    my %by_accept = (
        'application/json' => [200, 'application/json'],
        'text/html'        => [200, 'text/html; charset=utf-8'],
        'image/png'        => [406, 'text/plain; charset=utf-8'],
    );
    for my $accept (sort keys %by_accept) {
        my $res = $client->get('/note', headers => { Accept => $accept });
        is [$res->status, $res->header('Content-Type'), $res->header('Vary')],
            [@{$by_accept{$accept}}, 'Accept'], "$accept: status, type and Vary";
    }
};

subtest 'PAGI::ContentNegotiation: the EXAMPLES application' => sub {
    my $pod = do {
        open my $fh, '<', "$FindBin::Bin/../../lib/PAGI/ContentNegotiation.pm" or die $!;
        local $/;
        <$fh>;
    };
    my ($section) = $pod =~ /^=head2 Content Negotiation in a PAGI App\n(.*?)^=head1 /ms;
    my $code = join "\n", map { s/^    //mgr } grep { /\A[ \t]/ } split /\n{2,}/, $section =~ s/\A\n+//r;
    my $app = eval "package PAGITest::NegotiationExample; $code; \\&app";
    is $@, '', 'the example compiles and runs as published' or return;
    my $client = PAGI::Test::Client->new(app => $app);
    my %by_accept = (
        'application/json' => 'application/json',
        'text/html'        => 'text/html',
        'application/xml'  => 'application/xml',
    );
    for my $accept (sort keys %by_accept) {
        my $res = $client->get('/', headers => { Accept => $accept });
        is $res->header('Content-Type'), $by_accept{$accept}, "$accept is answered in kind";
    }
};

subtest 'PAGI::SSE: a client that leaves as the stream starts' => sub {
    my $app = synopsis_app('SSE', 'PAGITest::SSESynopsisLeaving') or return;
    my $client = PAGI::Test::Client->new(app => leaves_at_handshake($app));

    ok(lives { $client->sse('/events', sub { }) }, 'the handler does not die') or note $@;
    is \%PAGITest::SSESynopsisLeaving::subscribers, {}, 'and leaves no subscriber';
};

subtest 'PAGI::Routing' => sub {
    my $app = synopsis_app('Routing', 'PAGITest::RoutingSynopsis') or return;
    my $client = PAGI::Test::Client->new(app => $app);

    my $list = $client->get('/notes');
    is $list->status, 200, 'GET /notes answers';
    is $list->json, { notes => [], first => '/notes/1' },
        'and links the first note through its sibling name';
    ok $list->header('X-Request-ID'), 'the Router middleware ran';
    is $client->get('/notes/7')->json, { id => '7' }, 'GET /notes/7 answers its id';
    is $client->get('/notes/x')->status, 404, 'a constraint miss is 404';
    my $created = $client->post('/notes', json => { title => 'x' });
    is [$created->status, $created->json], [201, { title => 'x' }], 'POST /notes creates';
    my $patch = $client->patch('/notes');
    is [$patch->status, $patch->header('Allow')], [405, 'GET, HEAD, POST'],
        'PATCH /notes is 405 with the Allow union';
    is $app->path_for('/notes/note', { id => 3 }), '/notes/3',
        'the composed application resolves the mounted name';
    $client->websocket('/echo', sub {
        my ($ws) = @_;
        $ws->send_text('hi');
        is $ws->receive_text, 'echo: hi', '/echo echoes';
    });
};

done_testing;
