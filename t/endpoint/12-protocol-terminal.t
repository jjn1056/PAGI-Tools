use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use PAGI::Routing qw(router websocket sse);
use PAGI::Response qw(response);
use PAGI::Endpoint::WebSocket;
use PAGI::Endpoint::SSE;
use PAGI::Test::ConnectionState;

{ package T::TerminalWS; use parent 'PAGI::Endpoint::WebSocket'; sub handle { $_[0]{handler}->($_[1]) } }
{ package T::TerminalSSE; use parent 'PAGI::Endpoint::SSE'; sub handle { $_[0]{handler}->($_[1]) } }
{ package T::HookWS; use parent 'PAGI::Endpoint::WebSocket';
  sub on_connect { $_[0]{connect}->($_[1]) }
  sub on_disconnect { $_[0]{disconnect}->(@_[1..$#_]) }
}
{ package T::HookSSE; use parent 'PAGI::Endpoint::SSE';
  sub on_connect { $_[0]{connect}->($_[1]) }
  sub on_disconnect { $_[0]{disconnect}->(@_[1..$#_]) }
}
for my $kind (qw(websocket sse)) {
    for my $boundary (qw(route endpoint)) {
        for my $outcome (qw(active pending refusal failure explicit disconnect)) {
            subtest "$kind $boundary handler return: $outcome" => sub {
                my $conn = PAGI::Test::ConnectionState->new(websocket => $kind eq 'websocket');
                my @events;
                my $handler = async sub {
                    my ($h) = @_;
                    return if $outcome eq 'pending';
                    if ($outcome eq 'refusal') {
                        my $response = response('Text', 'no', status => 403);
                        await ($kind eq 'websocket' ? $h->deny($response) : $h->decline($response));
                        return;
                    }
                    await ($kind eq 'websocket' ? $h->accept : $h->start);
                    die "handler failed\n" if $outcome eq 'failure';
                    await $h->close if $outcome eq 'explicit';
                    $conn->_mark_disconnected('peer_closed', 'gone') if $outcome eq 'disconnect';
                    return;
                };
                my $endpoint = ($kind eq 'websocket' ? 'T::TerminalWS' : 'T::TerminalSSE')->new(handler => $handler);
                my $app = $boundary eq 'endpoint' ? $endpoint->to_app
                    : router(routes => [$kind eq 'websocket' ? websocket('/' => $handler) : sse('/' => $handler)])->to_app;
                my $future = $app->({type => $kind, path => '/', 'pagi.connection' => $conn}, sub {die 'receive'}, sub {
                    my ($e) = @_;
                    push @events, $e->{type};
                    # SSE callback delivery is an explicit scheduling boundary
                    # below; WS close deliberately leaves its peer pending.
                    Future->done;
                });
                my @expected = $outcome eq 'pending' ? () : $outcome eq 'refusal' ? qw(http.response.start http.response.body)
                    : ("$kind." . ($kind eq 'websocket' ? 'accept' : 'start'), ($outcome eq 'active' || $outcome eq 'explicit' ? "$kind.close" : ()));
                is(\@events, \@expected, 'boundary sends only missing terminal event');
                if ($outcome eq 'failure') { like($future->failure, qr/handler failed/, 'handler exception preserved'); }
                elsif ($kind eq 'websocket' || $outcome !~ /active|explicit/) { ok($future->is_ready, 'boundary returns without awaiting peer'); }
                $conn->_set_peer_close(1001, 'peer') if $kind eq 'websocket';
                $conn->_mark_complete;
                ok($future->is_ready, 'operation settles after terminal notification');
            };
        }
    }
    subtest "$kind endpoint registers async cleanup before on_connect" => sub {
        my $conn = PAGI::Test::ConnectionState->new(websocket => $kind eq 'websocket');
        my $gate = Future->new;
        my @calls;
        my $endpoint = ($kind eq 'websocket' ? 'T::HookWS' : 'T::HookSSE')->new(
            connect => sub { $conn->_mark_disconnected('peer_closed', 'during connect'); return Future->done },
            disconnect => sub { push @calls, [@_]; $gate },
        );
        my $f = $endpoint->to_app->({type => $kind, 'pagi.connection' => $conn}, sub { die 'receive' }, sub {die 'send'});
        is(scalar @calls, 1, 'cleanup observed end during connect');
        my $h = $calls[0][0];
        $h->on_error(sub {}); # object remains usable while cleanup is parked
        my $join = $h->_run_close_callbacks;
        ok(!$join->is_ready, 'adapter returns hook Future to retained cleanup');
        $gate->done;
        ok($join->is_ready, 'async endpoint cleanup awaited');
        ok($f->is_ready, 'handler finished');
    };
}
done_testing;
