use v5.24;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use File::Spec;

use PAGI::Response;

is(File::Spec->rel2abs($INC{'PAGI/Response.pm'}), File::Spec->rel2abs('lib/PAGI/Response.pm'), 'this checkout\'s PAGI::Response is the one loaded');

# Small responses, made here.
package Local::Hello { use parent -norequire, 'PAGI::Response'; }
# A body of its own, as Stream's will be: it says it doesn't know the length.
package Local::OwnBody { use parent -norequire, 'PAGI::Response'; sub content_length { undef } }
package Local::Typed { use parent -norequire, 'Local::OwnBody'; sub default_content_type { 'text/plain' } sub send_body { } }

# Runs a response for one request, returning what it sent and the call's Future.
sub serve {
    my ($response, %scope) = @_;
    my @sent;
    my $call = $response->call({ type => 'http', method => 'GET', %scope },
        sub { Future->new }, sub { push @sent, $_[0]; Future->done });
    return (\@sent, $call);
}

subtest 'buffered content: rendered once, sent as one event' => sub {
    my $r = PAGI::Response->new('abc');
    is($r->body, 'abc', 'body is public');
    is($r->content_length, 3, 'content_length');
    my ($sent, $call) = serve($r);
    ok($call->is_done, 'done');
    is($sent, [
        { type => 'http.response.start', status => 200,
          headers => [['content-type', 'application/octet-stream'], ['content-length', 3]] },
        { type => 'http.response.body', body => 'abc', more => 0 },
    ], 'start with type and length, then one event');
    my ($again) = serve($r);
    is($again, $sent, 'served again: the same (a reusable value)');
    is(PAGI::Response->new(content => 'abc')->body, 'abc', 'content by name');
};

package Local::Forgets { use parent -norequire, 'PAGI::Response'; use Future::AsyncAwait;
    async sub send_body { my ($self, $scope, $receive, $send) = @_; await $send->(main::body_event('a body of its own', 0)) } }
package main;

subtest 'no content: an empty body, its length and type unknown' => sub {
    my $r = PAGI::Response->new;
    is($r->content_length, undef, 'no content, no length');
    my ($sent) = serve($r);
    is($sent, [
        { type => 'http.response.start', status => 200, headers => [] },
        { type => 'http.response.body', body => '', more => 0 },
    ], 'no content-type, no content-length: the server frames it');
    my ($empty) = serve(PAGI::Response->new(''));
    is($empty->[0]{headers}, [['content-length', 0]], 'empty content given: its length is known, 0');
    my ($own) = serve(Local::Forgets->new);
    is($own->[0]{headers}, [], 'a body of its own, no override: no content-length is claimed');
    my ($nc) = serve(PAGI::Response->new(status => 204));
    is($nc, [
        { type => 'http.response.start', status => 204, headers => [] },
        { type => 'http.response.body', body => '', more => 0 },
    ], '204: start and an empty event');
};

subtest 'render refuses what is not bytes' => sub {
    like(dies { PAGI::Response->new("caf\x{e9} \x{263A}") }, qr/\APAGI::Response content must be bytes: .*encode it first, or use PAGI::Response::Text/,
        'a character above 0xFF');
    like(dies { PAGI::Response->new([1]) }, qr/\APAGI::Response content must be a string, not a ARRAY reference/, 'a reference');
    is(PAGI::Response->new("caf\xE9")->body, "caf\xE9", 'bytes 128-255 are bytes');
};

package Local::Logged { use parent -norequire, 'PAGI::Response'; use Future::AsyncAwait;
    async sub send_body { my ($self, @args) = @_; await $self->SUPER::send_body(@args) } }
package main;

subtest 'a send_body that wraps the base\'s keeps the buffered body\'s rules' => sub {
    my ($sent) = serve(Local::Logged->new('abc'));
    is($sent->[0]{headers}, [['content-type', 'application/octet-stream'], ['content-length', 3]], 'its type and length');
    like(dies { Local::Logged->new('abc', headers => [['content-length', 99]]) }, qr/\Athe content-length header says 99/, 'and its length check');
    ok(lives { Local::Sends->new(events => [], headers => [['content-length', 99]]) }, 'a body of its own, no content: its length is its own promise');
};

subtest 'a content-length that disagrees with the body' => sub {
    like(dies { PAGI::Response->new('abc', headers => [['Content-Length', 5]]) },
        qr/\Athe content-length header says 5 but the body is 3 bytes/, 'croaks at new');
    my ($sent) = serve(PAGI::Response->new('abc', headers => [['content-length', 3]]));
    is($sent->[0]{headers}, [['content-length', 3], ['content-type', 'application/octet-stream']], 'an agreeing one is sent once');
};

subtest 'headers: copied, and names lowercased (ASCII letters only)' => sub {
    my $r = Local::Hello->new(status => 201, headers => [['X-One', 'a'], ["X-\xC9tag", 'b']]);
    is($r->headers, [['x-one', 'a'], ["x-\xC9tag", 'b']], 'names lowercased, the non-ASCII byte kept');
    is($r->status, 201, 'status');
    my $shared = [['X-A', 1]];
    my ($r1, $r2) = (Local::Hello->new(headers => $shared), Local::Hello->new(headers => $shared));
    push @{ $r1->headers }, ['x-b', 2];
    $r1->headers->[0][1] = 'changed';
    is($r2->headers, [['x-a', 1]], 'the list and its pairs are copied');
    is($shared, [['X-A', 1]], 'and the caller\'s is untouched');
};

subtest 'the header rules' => sub {
    is(Local::Typed->new->response_headers(5), [['content-type', 'text/plain'], ['content-length', 5]], 'type and length');
    is(Local::Typed->new(content_type => 'text/csv')->response_headers(undef), [['content-type', 'text/csv']],
        'a given type; no length when unknown');
    is(Local::Typed->new(headers => [['Content-Type', 'x/y']])->response_headers(1), [['content-type', 'x/y'], ['content-length', 1]],
        'a content-type header wins; one content-type');
    is(Local::Typed->new(headers => [['content-length', 9]])->response_headers(9), [['content-length', 9], ['content-type', 'text/plain']],
        'a given length is not repeated');
    is(Local::Typed->new(status => 204)->response_headers(5), [], '204: no type, no length');
    is(Local::Typed->new(status => 304, headers => [['etag', '"x"']])->response_headers(5), [['etag', '"x"']], '304: its own headers only');
    is(Local::Typed->new(status => 101)->response_headers(5), [], '1xx: no type, no length');
    is(Local::Typed->new(status => 205)->response_headers(5), [['content-type', 'text/plain'], ['content-length', 0]], '205: length 0');
    is(Local::Hello->new->response_headers(undef), [], 'no default type: no header');
    my $resp = Local::Typed->new;
    my $before = $resp->response_headers(1);
    push @$before, ['x-junk', 1];
    $before->[0][1] = 'changed';
    is($resp->response_headers(1), [['content-type', 'text/plain'], ['content-length', 1]], 'a fresh list each call');
    my $own = Local::Hello->new(headers => [['x-a', 1]]);
    $own->response_headers(undef)->[0][1] = 'changed';
    is($own->headers, [['x-a', 1]], 'and changing it never changes the response');
};

subtest 'a content-length the status forbids' => sub {
    like(dies { Local::Hello->new(status => 204, headers => [['Content-Length', 5]]) },
        qr/\Aa 204 response has no body, so it can't have a content-length/, '204');
    like(dies { Local::Hello->new(status => 101, headers => [['content-length', 0]]) },
        qr/\Aa 101 response has no body, so it can't have a content-length/, '1xx');
    like(dies { Local::Hello->new(status => 205, headers => [['content-length', 9]]) },
        qr/\Aa 205 response has no body: its content-length must be 0/, '205, not 0');
    ok(lives { Local::Hello->new(status => 205, headers => [['content-length', 0]]) }, '205 with 0');
    ok(lives { Local::Hello->new(status => 304, headers => [['content-length', 1234]]) }, '304 may say the length it would have had (RFC 9110 8.6)');
};

subtest 'no_content_status' => sub {
    is([map { Local::Hello->new(status => $_)->no_content_status ? 1 : 0 } 100, 101, 199, 200, 204, 205, 206, 304, 404],
       [1, 1, 1, 0, 1, 1, 0, 1, 0], '1xx, 204, 205 and 304');
};

# Bodies for call: each sends what its name says.
package Local::Once { use parent -norequire, 'Local::OwnBody'; use Future::AsyncAwait;
    sub content_length { 2 }
    async sub send_body { my ($self, $scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.body', body => 'hi', more => 0 }) } }
package Local::Late { use parent -norequire, 'Local::OwnBody'; use Future::AsyncAwait; use Class::Tiny qw(gate);
    async sub send_body { my ($self, $scope, $receive, $send) = @_;
        await $self->gate;
        await $send->({ type => 'http.response.body', body => 'late', more => 0 }) } }
package Local::FailsFirst { use parent -norequire, 'Local::OwnBody'; use Future::AsyncAwait;
    async sub send_body { die "boom before\n" } }
package Local::FailsAfterOne { use parent -norequire, 'Local::OwnBody'; use Future::AsyncAwait;
    async sub send_body { my ($self, $scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.body', body => 'part', more => 1 });
        die "boom after\n" } }
package Local::Counting { use parent -norequire, 'Local::OwnBody'; use Future::AsyncAwait; use Class::Tiny qw(ran);
    async sub send_body { my ($self) = @_; ${ $self->ran }++ } }
package Local::Silent { use parent -norequire, 'Local::OwnBody'; use Future::AsyncAwait;
    async sub send_body { return } }
package Local::SendsStart { use parent -norequire, 'Local::OwnBody'; use Future::AsyncAwait;
    our $START_LINE;
    async sub send_body { my ($self, $scope, $receive, $send) = @_;
        BEGIN { $START_LINE = __LINE__ + 1 }
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'hi', more => 0 }) } }
package Local::Overlap { use parent -norequire, 'Local::OwnBody'; use Future::AsyncAwait;
    async sub send_body { my ($self, $scope, $receive, $send) = @_;
        my $first  = $send->({ type => 'http.response.body', body => 'a', more => 1 });   # not awaited: Www 0.7 allows it
        my $second = $send->({ type => 'http.response.body', body => 'b', more => 0 });
        await Future->needs_all($first, $second) } }
package Local::Conn { sub new { my ($class, %args) = @_; bless { connected => $args{connected} // 1 }, $class }
    sub is_connected { $_[0]{connected} } sub on_end { } }
package main;

# Calls a response for one request, returning what it sent and the call's Future.
sub run {
    my ($response, %scope) = @_;
    my @sent;
    my $call = $response->call({ type => 'http', method => 'GET', %scope },
        sub { Future->new }, sub { push @sent, $_[0]; Future->done });
    return (\@sent, $call);
}
sub types { [map { $_->{type} } @{ $_[0] }] }

subtest 'call: the start goes out just before the first body event' => sub {
    my ($sent, $call) = run(Local::Once->new);
    ok($call->is_done, 'done');
    is(types($sent), ['http.response.start', 'http.response.body'], 'start, then the body');
    is($sent->[0]{headers}, [['content-length', 2]], 'content_length asked for the start');

    my $gate = Future->new;
    my ($late, $pending) = run(Local::Late->new(gate => $gate));
    is(scalar @$late, 0, 'nothing sent before the first body event');
    $gate->done;
    is(types($late), ['http.response.start', 'http.response.body'], 'then the start, just before it');
    ok($pending->is_done, 'and the call completes');
};

subtest 'call: overlapping sends keep their order, with one start' => sub {
    my (@got, @pending);
    my $call = Local::Overlap->new->call({ type => 'http' }, sub { Future->new },
        sub { push @got, $_[0]; push @pending, my $f = Future->new; $f });   # a server that settles later
    while (@pending) { $_->done for splice @pending }
    is([map { $_->{body} // 'START' } @got], ['START', 'a', 'b'], 'start, a, b: in call order');
    ok($call->is_done, 'done');
};

subtest 'call: the base never overlaps its own sends' => sub {
    # A server that refuses a send while the last is still pending, as one
    # before Www.pod 0.7 may. A subclass that awaits each send must pass.
    my (@got, $pending, $overlapped);
    my $strict = sub {
        $overlapped++ if $pending && !$pending->is_ready;
        push @got, $_[0];
        return $pending = Future->new;
    };
    my $call = Local::Once->new->call({ type => 'http' }, sub { Future->new }, $strict);
    $pending->done while !$call->is_ready && $pending && !$pending->is_ready;
    ok(!$overlapped, 'the body waited for the start');
    is(types(\@got), ['http.response.start', 'http.response.body'], 'start, then the body');
    ok($call->is_done, 'done');
};

subtest 'call: failures' => sub {
    my ($first, $f1) = run(Local::FailsFirst->new);
    is(scalar @$first, 0, 'a failure before the first event: nothing sent');
    is($f1->failure, "boom before\n", 'the error leaves call');

    my ($after, $f2) = run(Local::FailsAfterOne->new);
    is(types($after), ['http.response.start', 'http.response.body'], 'one start, one event, no second start');
    is($f2->failure, "boom after\n", 'the error leaves call');

    my ($own, $f3) = run(Local::SendsStart->new);
    like($f3->failure, qr/\APAGI::Response sends the start; send_body sends only body events at \Q${\ __FILE__}\E line $Local::SendsStart::START_LINE\.\n\z/,
        'its own start croaks, naming the line that sent it');
    is(scalar @$own, 0, 'nothing reached the server');
};

subtest 'call: no-body statuses never run send_body' => sub {
    for my $status (204, 304, 205) {
        my $ran = 0;
        my ($sent) = run(Local::Counting->new(status => $status, ran => \$ran));
        is($ran, 0, "$status: send_body never runs");
        is($sent->[1], { type => 'http.response.body', body => '', more => 0 }, "$status: one empty terminal event");
        is(scalar @$sent, 2, "$status: start and the end");
    }
};

subtest 'call: a body that sends nothing' => sub {
    my ($empty) = run(Local::Silent->new);
    is(types($empty), ['http.response.start', 'http.response.body'], 'an empty body');
    is($empty->[1]{body}, '', 'empty');
    my ($gone) = run(Local::Silent->new, 'pagi.connection' => Local::Conn->new(connected => 0));
    is(scalar @$gone, 0, 'and the client gone: nothing at all');
    my ($here) = run(Local::Silent->new, 'pagi.connection' => Local::Conn->new(connected => 1));
    is(scalar @$here, 2, 'the client still there: the empty body');
};

subtest 'call: scopes' => sub {
    my ($ws) = run(Local::Once->new, type => 'websocket');
    is($ws->[0]{type}, 'http.response.start', 'a websocket scope: an HTTP refusal');
    my ($sse) = run(Local::Once->new, type => 'sse');
    is($sse->[0]{type}, 'http.response.start', 'an sse scope: an HTTP refusal');
    my (undef, $lifespan) = run(Local::Once->new, type => 'lifespan');
    is($lifespan->failure, "Unsupported scope type: lifespan\n", 'lifespan refused');
};

package Local::Sends { use parent -norequire, 'Local::OwnBody'; use Future::AsyncAwait; use Class::Tiny qw(events);
    async sub send_body { my ($self, $scope, $receive, $send) = @_; for my $event (@{ $self->events }) { await $send->($event) } } }
package Local::Checksum { use parent -norequire, 'PAGI::Response';
    sub trailers_for { my ($self, $scope) = @_; [['X-Checksum', "sha256=$scope->{method}"]] } }
package main;

sub body_event { { type => 'http.response.body', body => $_[0], more => $_[1] } }
sub trailers_event { { type => 'http.response.trailers', headers => $_[0] // [] } }

subtest 'trailers: a buffered body' => sub {
    my ($sent, $call) = serve(PAGI::Response->new('abc', trailers => 1));
    ok($call->is_done, 'done');
    is($sent, [
        { type => 'http.response.start', status => 200, trailers => 1,
          headers => [['content-type', 'application/octet-stream']] },
        body_event('abc', 0),
        trailers_event([]),
    ], 'start declares them and has no content-length; the body, then the trailers');
    my ($sum) = serve(Local::Checksum->new('abc', trailers => 1));
    is($sum->[2], trailers_event([['x-checksum', 'sha256=GET']]), 'trailers_for gives them, per request, names lowercased');
    my ($none) = serve(Local::Checksum->new('abc'));
    is(types($none), ['http.response.start', 'http.response.body'], 'not declared: no trailers');
    ok(!exists $none->[0]{trailers}, 'and the start says nothing about them');
};

subtest 'trailers: a body of its own' => sub {
    my ($sent, $call) = serve(Local::Sends->new(trailers => 1,
        events => [body_event('a', 1), body_event('b', 0), trailers_event([['X-Count', 2]])]));
    ok($call->is_done, 'done');
    is($sent, [
        { type => 'http.response.start', status => 200, trailers => 1, headers => [] },
        body_event('a', 1), body_event('b', 0), trailers_event([['x-count', 2]]),
    ], 'its events in order, trailer names lowercased');
    my ($forgot, $fcall) = serve(Local::Sends->new(trailers => 1, events => [body_event('a', 0)]));
    is(types($forgot), ['http.response.start', 'http.response.body'], 'declared but never sent: none are made up');
    like(scalar $fcall->failure, qr/\ALocal::Sends send_body returned without the trailers it declared: send one http\.response\.trailers event last/, 'and call fails');
    my ($silent) = serve(Local::Silent->new(trailers => 1));
    is(types($silent), ['http.response.start', 'http.response.body', 'http.response.trailers'], 'nothing sent: an empty body, then empty trailers');
    my ($gone) = serve(Local::Silent->new(trailers => 1), 'pagi.connection' => Local::Conn->new(connected => 0));
    is($gone, [], 'nothing sent and the client gone: nothing');
};

subtest 'trailers: misuse croaks, naming the line' => sub {
    my $case = sub {
        my ($name, $re, %args) = @_;
        my ($sent, $call) = serve(Local::Sends->new(%args));
        like(scalar $call->failure, qr/\A$re at \Q${\ __FILE__}\E line \d+\.\n\z/, $name);
    };
    $case->('not declared', qr/trailers sent, but none were declared: build the response with trailers => 1/,
        events => [body_event('a', 0), trailers_event()]);
    $case->('twice', qr/trailers already sent: a response has one trailers event/,
        trailers => 1, events => [body_event('a', 0), trailers_event(), trailers_event()]);
    $case->('a body event after them', qr/a body event after the trailers: the trailers end the response/,
        trailers => 1, events => [body_event('a', 0), trailers_event(), body_event('b', 0)]);
    $case->('before the body is done', qr/trailers before the body's last event: send it with more => 0 first/,
        trailers => 1, events => [body_event('a', 1), trailers_event()]);
};

subtest 'trailers: statuses and headers that rule them out' => sub {
    my ($sent) = serve(PAGI::Response->new(status => 204, trailers => 1));
    is($sent, [
        { type => 'http.response.start', status => 204, headers => [] },
        body_event('', 0),
    ], '204: no body, so no trailers, and the start declares none');
    like(dies { PAGI::Response->new('abc', trailers => 1, headers => [['Content-Length', 3]]) },
        qr/\Aa response with trailers can't have a content-length: HTTP\/1\.1 sends trailers only in chunked coding/,
        'a content-length with trailers croaks at new');
};

package Local::Drops { use parent -norequire, 'Local::OwnBody'; use Future::AsyncAwait;
    async sub send_body { my ($self, $scope, $receive, $send) = @_;
        $send->(main::body_event('a', 0));
        $send->(main::trailers_event()) if $self->trailers;
        return } }
package Local::WideCSV { use parent -norequire, 'PAGI::Response';
    sub render { my ($self, $rows) = @_; join '', map { join(',', @$_) . "\r\n" } @$rows } }
package Local::RendersRef { use parent -norequire, 'PAGI::Response'; sub render { {} } }
package Local::RendersUndef { use parent -norequire, 'PAGI::Response'; sub render { undef } }
package main;

subtest 'call: a send whose Future is dropped still goes out, in order' => sub {
    for my $trailers (0, 1) {
        my (@got, @pending);
        my $warnings = warnings {
            my $call = Local::Drops->new(trailers => $trailers)->call({ type => 'http' }, sub { Future->new },
                sub { push @got, $_[0]; push @pending, my $f = Future->new; $f });   # a server that settles later
            while (@pending) { $_->done for splice @pending }
            ok($call->is_done, "trailers $trailers: done");
        };
        is(types(\@got), ['http.response.start', 'http.response.body', ($trailers ? 'http.response.trailers' : ())],
            "trailers $trailers: the body reaches the server, before any trailers");
        is($warnings, [], "trailers $trailers: no warnings");
    }
};

subtest 'call: a body left open fails, and is never finished for it' => sub {
    my ($sent, $call) = serve(Local::Sends->new(events => [body_event('a', 1)]));
    is($sent, [{ type => 'http.response.start', status => 200, headers => [] }, body_event('a', 1)],
        'no last event is made up (Www.pod: a truncated response must be observable as truncated)');
    like(scalar $call->failure, qr/\ALocal::Sends send_body returned with the body unfinished: its last event had more => 1/, 'call fails');
    my ($trailed, $tcall) = serve(Local::Sends->new(trailers => 1, events => [body_event('a', 1)]));
    is(types($trailed), ['http.response.start', 'http.response.body'], 'with trailers declared: nothing more');
    like(scalar $tcall->failure, qr/the body unfinished/, 'and call fails');
    my ($gone, $gcall) = serve(Local::Sends->new(events => [body_event('a', 1)]), 'pagi.connection' => Local::Conn->new(connected => 0));
    ok($gcall->is_done, 'the client gone: stopping early is no error');
};

subtest 'render: what it returns must be bytes' => sub {
    like(dies { Local::WideCSV->new([[1, "\x{540D}"]]) }, qr/\ALocal::WideCSV content must be bytes: it has a character above 0xFF/,
        'an overriding render returning characters croaks');
    like(dies { Local::RendersRef->new('x') }, qr/\ALocal::RendersRef content must be a string, not a HASH reference/, 'a reference');
    like(dies { Local::RendersUndef->new('x') }, qr/\ALocal::RendersUndef render returned undef/, 'undef');
    is(Local::WideCSV->new([[1, 2]])->body, "1,2\r\n", 'bytes are kept');
};

subtest 'undefined content is no content' => sub {
    my $r;
    is(warnings { $r = PAGI::Response->new(undef) }, [], q{no warnings});
    is($r->body, '', 'an empty body');
    my ($sent) = serve($r);
    is($sent->[1], body_event('', 0), 'sent empty');
    is(PAGI::Response->new(content => undef)->content_length, undef, 'by name too');
};

subtest 'to_app' => sub {
    my @sent;
    Local::Once->new->to_app->({ type => 'http' }, sub { Future->new }, sub { push @sent, $_[0]; Future->done })->get;
    is(types(\@sent), ['http.response.start', 'http.response.body'], 'the code reference calls call');
};

done_testing;
