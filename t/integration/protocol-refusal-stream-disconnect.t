use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use IO::Async::Stream;
use IO::Socket::INET;
use Socket qw(AF_UNIX SOCK_STREAM);
use Scalar::Util qw(refaddr weaken);
use Time::HiRes qw(time);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";
use PAGITest::CurrentServer qw(current_server_unavailable);

BEGIN {
    my $server_unavailable = current_server_unavailable();
    plan skip_all => $server_unavailable if $server_unavailable;
    eval { require PAGI::Server::Connection; require Future::IO::Impl::IOAsync; 1 }
        or plan skip_all => "optional real-server dependencies unavailable: $@";
}
use PAGI::Server::Protocol::HTTP1;
use PAGI::WebSocket;
use PAGI::SSE;
use PAGI::Pages;
use PAGI::Response::Stream;
use Protocol::WebSocket::Frame;

my $h2 = eval { require PAGI::Server::Protocol::HTTP2;
    require Net::HTTP2::nghttp2::Session;
    PAGI::Server::Protocol::HTTP2->available };
my $loop = IO::Async::Loop->new;
diag "server=$INC{'PAGI/Server.pm'}; Tools=$INC{'PAGI/WebSocket.pm'}";
diag 'h2=' . ($h2 ? $INC{'Net/HTTP2/nghttp2/Session.pm'} : 'unavailable');

sub until_ready {
    my ($condition, $pump) = @_;
    my $deadline = time + 6;
    while (!$condition->() && time < $deadline) { $pump->() }
    return !!$condition->();
}

# The h2 setup follows the server's socketpair integration harness. Only
# transport bootstrap touches server construction; lifecycle assertions below
# use the scope's public connection object and Tools helpers.
sub transport {
    my ($version, $type, $app, $logs, $request_options) = @_;
    $request_options //= {};
    my $server = PAGI::Server->new(app => $app, host => '127.0.0.1', port => 0,
        quiet => 1, access_log => undef, shutdown_timeout => 1, http2 => $version eq '2',
        ws_close_timeout => 0.5, logger => sub { push @$logs, $_[0] });
    $loop->add($server);
    my ($sock, $stream, $connection, $client, $sid);
    my ($wire, $body, %headers) = ('', '');
    my $method = $request_options->{method} // 'GET';
    my $request_body = $request_options->{body} // '';
    my $extra_headers = $request_options->{headers} // [];
    if ($version eq '1.1') {
        $server->listen->get;
        $sock = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $server->port,
            Proto => 'tcp', Timeout => 5) or die "connect: $!";
        my @fields = $type eq 'websocket'
            ? (['Upgrade', 'websocket'], ['Connection', 'Upgrade'],
                ['Sec-WebSocket-Version', '13'],
                ['Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ=='])
            : (['Accept', 'text/event-stream']);
        push @fields, @$extra_headers;
        my $fields = join '', map { "$_->[0]: $_->[1]\r\n" } @fields;
        print $sock "$method / HTTP/1.1\r\nHost: localhost\r\n${fields}\r\n$request_body";
        $sock->blocking(0);
    } else {
        socketpair(my $a, $sock, AF_UNIX, SOCK_STREAM, 0) or die "socketpair: $!";
        $_->blocking(0) for $a, $sock;
        $stream = IO::Async::Stream->new(read_handle => $a, write_handle => $a,
            on_read => sub { 0 });
        $connection = PAGI::Server::Connection->new(stream => $stream, app => $app,
            protocol => PAGI::Server::Protocol::HTTP1->new, server => $server,
            h2_protocol => $server->{http2_protocol}, alpn_protocol => 'h2', ws_close_timeout => 0.5);
        $server->add_child($stream);
        $connection->start;
        $client = Net::HTTP2::nghttp2::Session->new_client(callbacks => {
            on_begin_headers => sub { 0 }, on_frame_recv => sub { 0 }, on_stream_close => sub { 0 },
            on_header => sub { my ($id, $name, $value) = @_; $headers{$name} = $value; 0 },
            on_data_chunk_recv => sub { $body .= $_[1]; 0 },
        });
        $loop->loop_once(0.1);
        my $settings = ''; $sock->sysread($settings, 4096);
        $client->send_connection_preface;
        $sock->syswrite($client->mem_send);
        $loop->loop_once(0.1);
        $client->mem_recv($settings);
        $loop->loop_once(0.1);
        my $ack = ''; $sock->sysread($ack, 4096); $client->mem_recv($ack) if length $ack;
        my $out = $client->mem_send; $sock->syswrite($out) if length $out;
        $loop->loop_once(0.1);
        my $extra = ''; $sock->sysread($extra, 4096); $client->mem_recv($extra) if length $extra;
        my @request_headers = $type eq 'websocket'
            ? ([':protocol', 'websocket'], ['sec-websocket-version', '13'])
            : (['accept', 'text/event-stream']);
        push @request_headers, map {
            [substr($_->[0], 0, 1) eq ':' ? $_->[0] : lc($_->[0]), $_->[1]]
        } @$extra_headers;
        my %request = (
            method => ($type eq 'websocket' ? 'CONNECT' : $method),
            path => '/', scheme => ($type eq 'websocket' ? 'https' : 'http'),
            authority => 'localhost', headers => \@request_headers,
        );
        $request{body} = sub { undef }
            if $type eq 'websocket' || exists $request_options->{body};
        $sid = $client->submit_request(%request);
        $client->submit_data($sid, $request_body, 1)
            if $type eq 'sse' && exists $request_options->{body};
        $sock->syswrite($client->mem_send);
    }
    my $pump = sub {
        $loop->loop_once(0.02);
        return unless defined fileno($sock);
        my $buf = ''; my $n = sysread($sock, $buf, 65536);
        if ($n) { $client ? $client->mem_recv($buf) : ($wire .= $buf) }
        if ($client) { my $out = $client->mem_send; $sock->syswrite($out) if length $out }
    };
    return {
        # The server owns only connections it accepts. The h2 connection is
        # built by hand, so the transport holds it; otherwise its weakened
        # read handler drops every frame once this sub returns.
        connection => $connection,
        pump => $pump,
        response => sub { return ($headers{':status'}, $body) if $version eq '2';
            my ($status) = $wire =~ m{HTTP/1\.1 (\d+)}; return ($status, $wire) },
        drop => sub { close $sock },
        close_frame => sub {
            my ($end) = @_;
            my $bytes = Protocol::WebSocket::Frame->new(type => 'close',
                buffer => pack('n', 1001) . 'peerbye', masked => 1)->to_bytes;
            if ($client) { $client->submit_data($sid, $bytes, $end // 0);
                $sock->syswrite($client->mem_send) }
            else { syswrite($sock, $bytes) }
        },
        finish => sub {
            close $sock if defined fileno($sock);
            if ($stream) { $stream->close_now } else { $server->shutdown->get }
            $loop->remove($server);
        },
    };
}

for my $version ('1.1', '2') {
    for my $type (qw(websocket sse)) {
        subtest "$type HTTP/$version direct Pages refusal" => sub {
            plan skip_all => 'optional HTTP/2 dependencies unavailable'
                if $version eq '2' && !$h2;
            my (%seen, @events, @logs, @warnings);
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            my $app = async sub {
                my ($scope, $receive, $send) = @_;
                return unless $scope->{type} eq $type;
                $seen{scope} = $scope;
                $seen{connection} = $scope->{'pagi.connection'};
                my $class = $type eq 'websocket' ? 'PAGI::WebSocket' : 'PAGI::SSE';
                my $method = $type eq 'websocket' ? 'deny' : 'decline';
                my $helper = $class->new($scope, $receive, async sub {
                    my ($event) = @_;
                    push @events, $event->{type};
                    return await $send->($event);
                });
                $seen{helper_scope} = $helper->scope;
                $helper->on_close(sub { ++$seen{cleanup}; return });
                await $helper->$method(PAGI::Pages->service_unavailable(
                    detail => 'Scheduled maintenance',
                    as => ($type eq 'websocket' ? 'text' : 'json'),
                ));
                ++$seen{returned};
                return;
            };
            my $options = $type eq 'sse'
                ? { headers => [['Accept', 'application/problem+json']] }
                : {};
            my $t = transport($version, $type, $app, \@logs, $options);
            ok until_ready(sub {
                my ($status, $body) = $t->{response}->();
                defined($status) && $status == 503
                    && $body =~ /Scheduled maintenance/ && $seen{cleanup};
            }, $t->{pump}), 'Pages refusal reaches the wire and terminates cleanly';
            my ($status, $body) = $t->{response}->();
            is $status, 503, 'Pages status';
            like $body, qr/Scheduled maintenance/, 'Pages body';
            is refaddr($seen{helper_scope}), refaddr($seen{scope}),
                'helper delegates with the original scope identity';
            is $seen{scope}{type}, $type, 'protocol scope type remains unchanged';
            is $seen{scope}{http_version}, $version, 'actual transport version';
            is \@events, ['http.response.start', 'http.response.body'],
                'no websocket.accept or sse.start';
            is $seen{cleanup}, 1, 'terminal callback runs once';
            is $seen{returned}, 1, 'delegated application settles once';
            ok $seen{connection}->response_complete, 'refusal is a clean completion';
            is $seen{connection}->disconnect_reason, undef,
                'clean refusal has no disconnect reason';
            $t->{finish}->();
            is $seen{cleanup}, 1, 'transport disposal does not duplicate cleanup';
            is \@logs, [], 'no unexpected server logs';
            is \@warnings, [], 'no unexpected warnings';
        };
    }

    subtest "sse HTTP/$version POST body reaches Request handler" => sub {
        plan skip_all => 'optional HTTP/2 dependencies unavailable'
            if $version eq '2' && !$h2;
        my (%seen, @events, @logs, @warnings);
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $app = async sub {
            my ($scope, $receive, $send) = @_;
            return unless $scope->{type} eq 'sse';
            $seen{scope} = $scope;
            $seen{connection} = $scope->{'pagi.connection'};
            my $sse = PAGI::SSE->new($scope, $receive, async sub {
                my ($event) = @_;
                push @events, $event->{type};
                return await $send->($event);
            });
            $sse->on_close(sub { ++$seen{cleanup}; return });
            await $sse->decline(async sub {
                my ($request) = @_;
                $seen{request_scope} = $request->scope;
                $seen{method} = $request->method;
                $seen{content_type} = $request->content_type;
                my $data = await $request->json;
                $seen{job} = $data->{job};
                return PAGI::Pages->service_unavailable(
                    as => 'json', extensions => { job => $data->{job} },
                );
            });
            ++$seen{returned};
            return;
        };
        my $request_body = '{"job":42}';
        my $t = transport($version, 'sse', $app, \@logs, {
            method => 'POST', body => $request_body,
            headers => [
                ['Accept', 'application/problem+json'],
                ['Content-Type', 'application/json'],
                ['Content-Length', length($request_body)],
            ],
        });
        ok until_ready(sub {
            my ($status, $body) = $t->{response}->();
            defined($status) && $status == 503
                && $body =~ /"job"\s*:\s*42/ && $seen{cleanup};
        }, $t->{pump}), 'POST body handler returns its JSON refusal';
        my ($status, $body) = $t->{response}->();
        is $status, 503, 'handler refusal status';
        like $body, qr/"job"\s*:\s*42/, 'response contains decoded job';
        is [$seen{method}, $seen{content_type}, $seen{job}],
            ['POST', 'application/json', 42],
            'Request decoded native sse.request body and metadata';
        is refaddr($seen{request_scope}), refaddr($seen{scope}),
            'Request handler receives the original scope identity';
        is $seen{scope}{http_version}, $version, 'actual transport version';
        is \@events, ['http.response.start', 'http.response.body'],
            'body handler emits no sse.start';
        is [$seen{cleanup}, $seen{returned}], [1, 1],
            'cleanup and delegated application settle once';
        ok $seen{connection}->response_complete, 'refusal is a clean completion';
        is $seen{connection}->disconnect_reason, undef,
            'clean refusal has no disconnect reason';
        $t->{finish}->();
        is $seen{cleanup}, 1, 'transport disposal does not duplicate cleanup';
        is \@logs, [], 'no unexpected server logs';
        is \@warnings, [], 'no unexpected warnings';
    };
}

for my $version ('1.1', '2') {
    for my $type (qw(websocket sse)) {
        subtest "$type HTTP/$version parked refusal releases resources after client drop" => sub {
            plan skip_all => 'optional HTTP/2 dependencies unavailable' if $version eq '2' && !$h2;
            my (%seen, @events, @io, @logs, @warnings);
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            my $app = async sub {
                my ($scope, $receive, $send) = @_;
                return unless $scope->{type} eq $type;
                $seen{scope} = $scope;
                my $helper = ($type eq 'websocket' ? 'PAGI::WebSocket' : 'PAGI::SSE')->new(
                    $scope, $receive, sub {
                        push @events, $_[0]->{type};
                        my $f = $send->(@_); push @io, $f;
                        $f->on_cancel(sub { ++$seen{io_cancelled} }); return $f;
                    });
                $helper->on_close(sub { ++$seen{helper_cleanup}; return });
                my $response = PAGI::Response::Stream->new(sub {
                    my ($writer) = @_;
                    $seen{writer} = $writer; weaken($seen{writer});
                    $writer->on_close(sub { ++$seen{writer_cleanup}; return });
                    my $producer = (async sub {
                        await $writer->write('refusal-chunk');
                        $seen{parked} = 1;
                        await Future->new;
                    })->();
                    $producer->on_cancel(sub { ++$seen{producer_cancelled} });
                    $seen{producer} = $producer; weaken($seen{producer});
                    return $producer;
                }, status => 403, content_type => 'text/plain');
                my $rejection = $type eq 'websocket' ? $helper->deny($response) : $helper->decline($response);
                await $rejection;
                $seen{settled} = 1;
                return;
            };
            my $t = transport($version, $type, $app, \@logs);
            ok until_ready(sub { my ($status, $body) = $t->{response}->();
                $seen{parked} && defined $status && $body =~ /refusal-chunk/ }, $t->{pump}), 'body arrives while producer parks';
            my ($status, $body) = $t->{response}->();
            is $status, 403, 'ordinary HTTP refusal status';
            like $body, qr/refusal-chunk/, 'refusal body delivered';
            is $seen{scope}{http_version}, $version, 'actual transport version';
            is $seen{scope}{pagi}{spec_version}, '0.6', 'current normative scope';
            ok $seen{producer} && $seen{writer}, 'weak references see live parked resources';
            ok !$seen{settled}, 'refusal remains pending before drop';
            $t->{drop}->();
            ok until_ready(sub { $seen{settled} && $seen{helper_cleanup} }, $t->{pump}), 'refusal and helper cleanup settle';
            is $seen{producer_cancelled}, 1, 'owned producer cancelled once';
            is $seen{writer_cleanup}, 1, 'writer cleanup exactly once';
            is $seen{helper_cleanup}, 1, 'helper cleanup exactly once';
            ok !$seen{producer}, 'producer reference released';
            ok !$seen{writer}, 'writer reference released';
            is $seen{io_cancelled} // 0, 0, 'server I/O never cancelled';
            ok !scalar(grep { $_->is_cancelled } @io), 'actual send Futures remain uncancelled';
            is \@events, ['http.response.start', 'http.response.body'], 'no acceptance/start or terminal send after drop';
            my $connection = $seen{scope}{'pagi.connection'};
            ok !$connection->is_connected, 'public connection is terminal';
            like $connection->disconnect_reason, qr/^(?:client_closed|read_error|write_error)$/, 'public transport-loss token';
            ok !$connection->response_complete, 'partial refusal is not clean completion';
            $t->{finish}->();
            is \@logs, [], 'no unexpected server logs';
            is \@warnings, [], 'no unexpected warnings';
        };
    }
}

for my $case (
    ['1.1', 'application', undef],
    ['1.1', 'peer', undef],
    ['2', 'application', 'close_incomplete'],
) {
    my ($version, $initiator, $reason) = @$case;
    subtest "accepted WS HTTP/$version $initiator close " . ($reason // 'clean') => sub {
        plan skip_all => 'optional HTTP/2 dependencies unavailable' if $version eq '2' && !$h2;
        my (%seen, @logs, @warnings);
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $cleanup = Future->new;
        my $handler = Future->new;
        my $app = async sub {
            my ($scope, $receive, $send) = @_;
            return unless $scope->{type} eq 'websocket';
            my $ws = PAGI::WebSocket->new($scope, $receive, $send);
            $seen{connection} = $scope->{'pagi.connection'};
            $seen{helper} = $ws; weaken($seen{helper});
            $ws->on_close(sub {
                $seen{metadata} = [@_];
                ++$seen{cleanup};
                return $cleanup;
            });
            $ws->on_close(sub { ++$seen{cleanup_tail}; return });
            await $ws->accept;
            $seen{accepted} = 1;
            if ($initiator eq 'application') {
                await $ws->close(1000, 'applicationbye');
                $seen{close_sent} = 1;
            }
            # Keep the peer-first handler off receive: server on_end must
            # trigger helper cleanup independently of application progress.
            await $handler if $initiator eq 'peer';
            $seen{returned} = 1;
            return;
        };
        my $t = transport($version, 'websocket', $app, \@logs);
        ok until_ready(sub { $seen{accepted} && ($initiator eq 'peer' || $seen{close_sent}) }, $t->{pump}),
            'handshake and local close settle';
        ok !$seen{cleanup}, 'close send alone does not publish terminal cleanup';
        my $connection = $seen{connection};
        ok $connection->is_connected, 'connection remains live before peer Close';
        $t->{close_frame}->(0);
        ok until_ready(sub { $seen{cleanup} }, $t->{pump}), 'terminal callback arrives without receive';
        ok !$connection->is_connected, 'public terminal connection';
        is $connection->disconnect_reason, $reason, 'normative lifecycle reason';
        is $connection->close_code, 1001, 'server preserves peer code';
        is $connection->close_reason, 'peerbye', 'server preserves peer text';
        is $seen{metadata}, [1001, 'peerbye', $connection->disconnect_detail], 'helper callback agrees with server metadata';
        is $seen{helper}->disconnect_reason, $reason, 'helper lifecycle reason agrees';
        is $seen{cleanup}, 1, 'one terminal cleanup';
        ok !$seen{cleanup_tail}, 'later cleanup waits for parked first hook';
        $handler->done unless $handler->is_ready;
        ok until_ready(sub { $seen{returned} }, $t->{pump}), 'handler returns while cleanup remains parked';
        ok $seen{helper}, 'helper retained after handler return';
        $cleanup->done;
        ok until_ready(sub { $seen{cleanup_tail} }, $t->{pump}), 'parked cleanup finishes';
        is $seen{cleanup_tail}, 1, 'second hook runs once';
        ok !$seen{helper}, 'helper released after cleanup';
        $t->{finish}->();
        is $seen{cleanup}, 1, 'transport disposal does not duplicate cleanup';
        is \@logs, [], 'no unexpected server logs';
        is \@warnings, [], 'no unexpected warnings';
    };
}

done_testing;
