use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr weaken);
use File::Temp qw(tempfile);
use lib 't/lib';
use PAGITest::RefusalHarness;
use PAGI::Response qw(text_response);
use PAGI::Response::File;
use PAGI::Response::Stream;
use PAGI::Pages;
use PAGI::Routing qw(request_response);
use PAGI::Utils qw(as_app_object);

{
    package T::RefusalApp;
    sub new { bless { app => $_[1], calls => 0 }, $_[0] }
    sub to_app { ++$_[0]{calls}; $_[0]{app} }
    package T::PrivateTrap;
    our @ISA = ('T::RefusalApp');
    sub _emit { die 'private emitter called' }
    package T::RefusalRequest;
    our @ISA = ('PAGI::Request');
}

for my $kind (qw(websocket sse)) {
    my $method = $kind eq 'websocket' ? 'deny' : 'decline';
    subtest "$kind public application dispatch" => sub {
        my ($fh, $path) = tempfile(UNLINK => 1);
        print {$fh} 'Unavailable'; close $fh;
        for my $form (qw(sync async native buffered file stream pages custom trap wrapped factory)) {
            subtest $form => sub {
                my $remaining = $kind eq 'websocket'
                    ? { type => 'websocket.receive', text => 'remaining' }
                    : { type => 'sse.request', body => 'remaining', more => 0 };
                my $h = PAGITest::RefusalHarness->new($kind, input => [$remaining]);
                my $native = async sub {
                    my ($scope, $receive, $send) = @_;
                    is(refaddr($scope), refaddr($h->{scope}), 'original scope');
                    is(refaddr($receive), refaddr($h->{receive}), 'original receive');
                    is(refaddr($send), refaddr($h->{send}), 'original send');
                    is(await $receive->(), $remaining, 'remaining native input unchanged');
                    await $send->({ type => 'http.response.start', status => 503, headers => [] });
                    await $send->({ type => 'http.response.body', body => 'Unavailable', more => 0 });
                };
                my $handler_calls = 0;
                my $handler = sub {
                    ++$handler_calls;
                    is(scalar @_, 1, 'one Request argument');
                    my ($request) = @_;
                    isa_ok($request, ['PAGI::Request']);
                    is(refaddr($request->scope), refaddr($h->{scope}), 'handler original scope');
                    is($request->scope->{type}, $kind, 'native type');
                    return text_response('Unavailable', status => 503);
                };
                my $target = $form eq 'sync' ? $handler
                    : $form eq 'async' ? async sub { $handler->(@_); return PAGI::Pages->service_unavailable }
                    : $form eq 'native' ? sub { $handler->(@_); return $native }
                    : $form eq 'buffered' ? text_response('Unavailable', status => 503)
                    : $form eq 'file' ? PAGI::Response::File->new($path, status => 503)
                    : $form eq 'stream' ? PAGI::Response::Stream->new(async sub { await $_[0]->write('Unavailable') }, status => 503)
                    : $form eq 'pages' ? PAGI::Pages->service_unavailable
                    : $form eq 'custom' ? T::RefusalApp->new($native)
                    : $form eq 'trap' ? T::PrivateTrap->new($native)
                    : $form eq 'wrapped' ? as_app_object($native)
                    : request_response(sub { isa_ok($_[0], ['T::RefusalRequest']); $handler->(@_) }, request_factory => sub {
                        is(refaddr($_[0]), refaddr($h->{scope}), 'factory scope');
                        is(refaddr($_[1]), refaddr($h->{receive}), 'factory receive');
                        return T::RefusalRequest->new(@_);
                    });
                my $result;
                ok(lives { $result = $h->{helper}->$method($target)->get }, 'public invocation succeeds');
                is(refaddr($result), refaddr($h->{helper}), 'fluent identity');
                is($h->{events}[0]{status}, 503, 'expected HTTP status');
                ok(!$h->{events}[-1]{more}, 'terminal body');
                is($handler_calls, 1, 'handler called once') if $form =~ /^(?:sync|async|native|factory)$/;
                is($target->{calls}, 1, 'converted once') if $form eq 'custom' || $form eq 'trap';
                $h->deliver;
            };
        }
    };
}

for my $kind (qw(websocket sse)) {
    my $method = $kind eq 'websocket' ? 'deny' : 'decline';
    my $initial = $kind eq 'websocket' ? 'connecting' : 'pending';
    subtest "$kind settlement follows public connection facts" => sub {
        for my $mode (qw(prestart poststart terminal empty partial)) {
            my $h = PAGITest::RefusalHarness->new($kind);
            my $closed = 0;
            $h->{helper}->on_close(sub { ++$closed });
            $h->{helper}->keepalive(17, 'saved')->get if $kind eq 'sse';
            my $app = as_app_object(async sub {
                my ($scope, $receive, $send) = @_;
                await $send->({type => 'http.response.start', status => 503, headers => []})
                    if $mode eq 'poststart' || $mode eq 'partial';
                $h->{connection}->_mark_disconnected('client_closed') if $mode eq 'terminal';
                die "controlled $mode failure\n" unless $mode eq 'empty' || $mode eq 'partial';
                return;
            });
            if ($mode eq 'empty' || $mode eq 'partial') {
                is(refaddr($h->{helper}->$method($app)->get), refaddr($h->{helper}), "$mode return succeeds");
            } else {
                like(dies { $h->{helper}->$method($app)->get }, qr/controlled $mode failure/, 'original error');
            }
            if ($mode eq 'prestart' || $mode eq 'empty') {
                is($h->{helper}->connection_state, $initial, 'live unstarted slot remains available');
                is($closed, 0, 'app return is not termination');
                if ($kind eq 'sse') {
                    $h->{helper}->start->get;
                    is([map { $_->{type} } @{$h->{events}}], ['sse.start', 'sse.keepalive'], 'normal start arms saved keepalive despite response_started');
                } else {
                    $h->{helper}->$method(text_response('recovered', status => 503))->get;
                    is($h->{events}[0]{status}, 503, 'sequential retry can respond');
                }
            } else {
                like(dies { $h->{helper}->$method(text_response('again', status => 503))->get }, qr/(before|started|connected|pending|connecting)/i, 'sequential repeat rejected');
                is($closed, $mode eq 'terminal' ? 1 : 0, 'only connection terminal runs cleanup');
                my $before = @{$h->{events}};
                if ($kind eq 'sse') {
                    $h->{helper}->start->get;
                    $h->{helper}->keepalive(5)->get;
                    $h->{helper}->send('no')->get unless $mode eq 'terminal';
                } else { $h->{helper}->accept->get }
                is(scalar @{$h->{events}}, $before, 'protocol cannot reopen response');
            }
            $h->{connection}->_mark_disconnected('client_closed');
            $h->deliver;
        }
    };
    subtest "$kind cancellation reaches handlers and protects submitted buffered sends" => sub {
        for my $stage (qw(handler start body)) {
            my $gate = Future->new;
            my $h = PAGITest::RefusalHarness->new($kind, send => sub {
                my ($event) = @_;
                return $gate if $stage eq 'start' && $event->{type} eq 'http.response.start';
                return $gate if $stage eq 'body' && $event->{type} eq 'http.response.body';
                return Future->done;
            });
            my $closed = 0;
            $h->{helper}->on_close(sub { ++$closed });
            my $calls = 0;
            my $operation = $h->{helper}->$method(async sub {
                ++$calls;
                await $gate if $stage eq 'handler';
                return text_response('finished', status => 503);
            });
            ok(!$operation->is_ready, "$stage work pending");
            my $weak = $h->{helper}; weaken($weak);
            $operation->cancel;
            ok($operation->is_cancelled, 'ordinary operation cancelled');
            is($gate->is_cancelled ? 1 : 0, $stage eq 'handler' ? 1 : 0,
                'cancels handler dependency but protects submitted server send');
            my $before = scalar @{$h->{events}};
            is($h->{events}, [], 'cancelled handler emits no response') if $stage eq 'handler';
            undef $operation;
            delete $h->{helper};
            $h->{connection}->_mark_disconnected('client_closed');
            $h->deliver;
            is($calls, 1, 'handler invoked once');
            is($closed, 1, 'connection cleanup once');
            ok(!defined $weak, "$stage cancelled work releases helper after connection cleanup");
            $gate->done unless $gate->is_ready;
            is(scalar @{$h->{events}}, $before, 'send settlement cannot continue cancelled response');
        }
    };
    subtest "$kind delegated Stream cancellation matches direct invocation" => sub {
        for my $stage (qw(start body)) {
            for my $delegated (0, 1) {
                my $gate = Future->new;
                my $cleanup_gate = Future->new;
                my ($producer, $producer_calls, $cleanup_calls, $helper_cleanup) = (undef, 0, 0, 0);
                my $h = PAGITest::RefusalHarness->new($kind, send => sub {
                    my ($event) = @_;
                    return $gate if $stage eq 'start' && $event->{type} eq 'http.response.start';
                    return $gate if $stage eq 'body' && $event->{type} eq 'http.response.body';
                    return Future->done;
                });
                $h->{helper}->on_close(async sub { ++$helper_cleanup; await $cleanup_gate });
                my $stream = PAGI::Response::Stream->new(sub {
                    my ($writer) = @_;
                    ++$producer_calls;
                    $writer->on_close(async sub { ++$cleanup_calls; await $cleanup_gate });
                    return $producer = (async sub { await $writer->write('pending') })->();
                }, status => 403);
                my $operation = $delegated ? $h->{helper}->$method($stream)
                    : PAGI::Utils::invoke_app($stream, $h->{scope}, $h->{receive}, $h->{send});
                $operation->cancel;
                ok($operation->is_cancelled, "$stage delegated=$delegated operation cancelled");
                ok(!$gate->is_ready, 'server send remains pending and uncancelled');
                is($h->{connection}->disconnect_reason, 'app_abort', 'Stream requests its ordinary abort');
                ok($producer->is_cancelled, 'Stream cancels producer') if $stage eq 'body';
                $h->deliver;
                is($helper_cleanup, 1, 'helper cleanup starts once at connection end');
                ok(!$cleanup_gate->is_ready, 'asynchronous cleanup remains owned');
                $gate->done;
                is($producer_calls, $stage eq 'body' ? 1 : 0, 'no producer starts after cancelled response start');
                is($cleanup_calls, $stage eq 'body' ? 1 : 0, 'registered Writer cleanup starts once');
                is([map { $_->{type} } @{$h->{events}}],
                    $stage eq 'body' ? ['http.response.start', 'http.response.body'] : ['http.response.start'],
                    'no terminal success or subsequent body follows cancellation');
                $cleanup_gate->done;
                $h->deliver;
                is($helper_cleanup, 1, 'helper cleanup is once-only');
                is($cleanup_calls, $stage eq 'body' ? 1 : 0, 'Writer cleanup is once-only');
            }
        }
    };
    subtest "$kind admission and normalization failures preserve public boundaries" => sub {
        for my $cause (qw(to_app factory handler async_handler result)) {
            my $h = PAGITest::RefusalHarness->new($kind);
            my $target = $cause eq 'to_app' ? bless({}, 'T::BrokenRefusalApp')
                : $cause eq 'factory' ? request_response(sub { die 'handler must not run' }, request_factory => sub { die "factory failed\n" })
                : $cause eq 'handler' ? sub { die "handler failed\n" }
                : $cause eq 'async_handler' ? async sub { await Future->fail("async_handler failed\n") }
                : sub { return 'not an application' };
            like(dies { $h->{helper}->$method($target)->get },
                $cause eq 'result' ? qr/handler must return.*application/ : qr/$cause failed/, "$cause error propagates");
            is($h->{events}, [], 'no replacement response');
            is($h->{helper}->connection_state, $initial, 'prestart error leaves admission available');
            $h->{helper}->$method(text_response('retry', status => 503))->get;
            $h->deliver;
        }
        my $h = PAGITest::RefusalHarness->new($kind);
        $h->{connection}->_mark_response_started;
        my $target = T::RefusalApp->new(sub { die 'must not invoke' });
        like(dies { $h->{helper}->$method($target)->get }, qr/no response started/, 'public progress prevents admission even when helper phase is initial');
        is($target->{calls}, 0, 'claimed connection rejected before conversion');
        $h->{connection}->_mark_disconnected('client_closed');
    };
    subtest "$kind accepted streams still send after claiming response start" => sub {
        my $h = PAGITest::RefusalHarness->new($kind);
        if ($kind eq 'websocket') {
            $h->{helper}->accept->get;
            $h->{helper}->send_text('accepted')->get;
            ok($h->{helper}->try_send_text('also accepted')->get, 'accepted try_send succeeds');
            is([map { $_->{type} } @{$h->{events}}],
                ['websocket.accept', 'websocket.send', 'websocket.send'], 'accepted protocol sends remain usable');
        } else {
            $h->{helper}->keepalive(17, 'saved')->get;
            $h->{helper}->start->get;
            $h->{helper}->send('accepted')->get;
            is([map { $_->{type} } @{$h->{events}}],
                ['sse.start', 'sse.keepalive', 'sse.send'], 'normal start arms keepalive and sends');
        }
        $h->{connection}->_mark_disconnected('client_closed');
        $h->deliver;
    };
    subtest "$kind missing capability rejects every target before execution" => sub {
        my $calls = 0;
        my @targets = (
            sub { ++$calls; text_response('no', status => 503) },
            async sub { ++$calls; return PAGI::Pages->service_unavailable },
            sub { ++$calls; return sub { ++$calls } },
            text_response('no', status => 503),
            PAGI::Pages->service_unavailable,
            T::RefusalApp->new(sub { ++$calls }),
            as_app_object(sub { ++$calls }),
            request_response(sub { ++$calls }, request_factory => sub { ++$calls; PAGI::Request->new(@_) }),
            PAGI::Response::File->new('/unused/refusal-file', status => 503),
            PAGI::Response::Stream->new(sub { ++$calls }, status => 503),
        );
        subtest 'a pre-0.6 scope is refused at construction' => sub {
            my $scope = {type => $kind, pagi => {spec_version => '0.2'}};
            like(dies {
                ($kind eq 'websocket' ? 'PAGI::WebSocket' : 'PAGI::SSE')->new($scope, sub { Future->new }, sub { ++$calls; Future->done });
            }, qr/requires PAGI::Spec::Www 0\.6 or later; server reports spec_version 0\.2/, 'the diagnostic names the advertised version');
        };
        is($calls, 0, 'no factories handlers apps or sends invoked');
        is($targets[5]{calls}, 0, 'no to_app conversion');
        for my $target (@targets) {
            for my $missing (qw(response_started is_connected on_end disconnect_reason disconnect_detail), ($kind eq 'websocket' ? qw(close_code close_reason) : ())) {
                my $connection = bless {missing => $missing}, 'T::MissingCapability';
                # A 0.6 claim is not proof: the capabilities are still checked.
                my $scope = {type => $kind, pagi => {spec_version => '0.6'}, 'pagi.connection' => $connection};
                like(dies {
                    my $helper = ($kind eq 'websocket' ? 'PAGI::WebSocket' : 'PAGI::SSE')->new($scope, sub { Future->new }, sub { ++$calls });
                    $helper->$method($target)->get;
                }, qr/pagi\.connection.*$missing.*0\.6/, "missing $missing diagnosed");
            }
        }
        is($calls, 0, 'invalid connection prevents all user execution');
        is($targets[5]{calls}, 0, 'invalid connection prevents to_app');
    };
}
subtest 'partial HTTP response blocks every SSE auto-start entry point' => sub {
    my @entries = (
        [start => sub { $_[0]->start }],
        [run => sub { $_[0]->run }],
        [keepalive => sub { $_[0]->keepalive(3) }],
        [close => sub { $_[0]->close }],
        [send => sub { $_[0]->send('no') }],
        [send_json => sub { $_[0]->send_json({no => 1}) }],
        [send_event => sub { $_[0]->send_event(data => 'no') }],
        [send_comment => sub { $_[0]->send_comment('no') }],
        [try_send => sub { $_[0]->try_send('no') }],
        [try_send_json => sub { $_[0]->try_send_json({no => 1}) }],
        [try_send_event => sub { $_[0]->try_send_event(data => 'no') }],
        [try_send_comment => sub { $_[0]->try_send_comment('no') }],
        [each => sub { $_[0]->each([1], async sub { die 'must not dispatch after HTTP response' }) }],
        [every => sub { $_[0]->every(1, async sub { die 'must not dispatch after HTTP response' }) }],
    );
    for my $entry (@entries) {
        my ($name, $invoke) = @$entry;
        if ($name eq 'every' && !eval { require Future::IO::Impl::IOAsync; 1 }) {
            skip('Future::IO::Impl::IOAsync required for every guard', 1);
            next;
        }
        my $h = PAGITest::RefusalHarness->new('sse');
        $h->{helper}->keepalive(17)->get;
        $h->{helper}->decline(as_app_object(async sub {
            await $_[2]->({type => 'http.response.start', status => 403, headers => []});
        }))->get;
        my $operation = $invoke->($h->{helper});
        ok($operation->is_ready, "$name returns without waiting for terminal cleanup");
        if ($operation->is_ready) {
            my $result;
            ok(lives { $result = $operation->get }, "$name is safe after a partial HTTP response");
            ok(!$result, "$name returns false") if $name =~ /^try_/;
        } else { $operation->cancel }
        is([map { $_->{type} } @{$h->{events}}], ['http.response.start'], "$name emits no protocol event");
        ok(!exists $h->{helper}{_pending_keepalive}, "$name discards saved keepalive")
            if $name =~ /^(?:start|run|keepalive)$/;
        $h->{connection}->_mark_disconnected('client_closed');
        $h->deliver;
    }
};

{
    package T::BrokenRefusalApp;
    sub to_app { die "to_app failed\n" }
    package T::MissingCapability;
    sub can { return undef if $_[1] eq $_[0]{missing}; return sub {} }
    our $AUTOLOAD;
    sub AUTOLOAD { return 1 }
    sub DESTROY {}
}
done_testing;
