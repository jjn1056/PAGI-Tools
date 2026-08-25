use strict;
use warnings;
use Test2::V0;
use PAGI::SendValidation;

# ==========================================================================
# HTTP
# ==========================================================================

subtest 'http: legal happy path (no trailers) advances to complete' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http');
    is $sv->started, 0, 'not started before any send';
    is $sv->check({ type => 'http.response.start', status => 200 }), undef, 'start is legal';
    is $sv->started, 1, 'started after start';
    is $sv->complete, 0, 'not complete yet';
    is $sv->check({ type => 'http.response.body', body => 'hi', more => 1 }), undef, 'non-terminal chunk legal';
    is $sv->complete, 0, 'still not complete after more=>1 chunk';
    is $sv->check({ type => 'http.response.body', body => '!' }), undef, 'terminal chunk (no more) legal';
    is $sv->complete, 1, 'complete after terminal chunk';
    is $sv->finalize, undef, 'finalize legal once complete';
};

subtest 'http: legal happy path with declared trailers' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http');
    is $sv->check({ type => 'http.response.start', status => 200, trailers => 1 }), undef, 'start declaring trailers';
    is $sv->trailers_declared, 1, 'trailers_declared true';
    ok $sv->finalize, 'finalize illegal before body sent';
    is $sv->check({ type => 'http.response.body', body => 'x' }), undef, 'terminal body chunk legal';
    is $sv->complete, 0, 'not complete: still awaiting declared trailers';
    my $err = $sv->finalize;
    ok $err, 'finalize illegal while awaiting trailers';
    like $err->message, qr/trailer/i, 'finalize error names the missing trailers';
    is $sv->check({ type => 'http.response.trailers', headers => [] }), undef, 'trailers now legal';
    is $sv->complete, 1, 'complete once trailers sent';
    is $sv->finalize, undef, 'finalize legal';
};

subtest 'http: missing type (verbatim probed class)' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http');
    my $err = $sv->check({ status => 200 });
    ok $err, 'missing type is illegal';
    is $err->category, 'malformed', 'category malformed (not unknown_type: no type to even evaluate)';
    is $sv->started, 0, 'illegal event did not advance state';
    is $sv->check({ type => 'http.response.start', status => 200 }), undef, 'legal event after rejection still works';
};

subtest 'http: unrecognized event type http.response.bogus (verbatim probed class)' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http');
    my $err = $sv->check({ type => 'http.response.bogus' });
    ok $err, 'bogus type is illegal';
    is $err->category, 'unknown_type', 'category unknown_type';
    is $sv->check({ type => 'http.response.start', status => 200 }), undef, 'legal event after rejection still works';
};

subtest 'http: duplicate http.response.start (verbatim probed class)' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http');
    is $sv->check({ type => 'http.response.start', status => 200 }), undef, 'first start legal';
    my $err = $sv->check({ type => 'http.response.start', status => 200 });
    ok $err, 'duplicate start is illegal';
    is $err->category, 'sequence', 'category sequence';
    is $sv->check({ type => 'http.response.body', body => 'ok' }), undef, 'legal event after rejection still works';
};

subtest 'http: body before start' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http');
    my $err = $sv->check({ type => 'http.response.body', body => 'x' });
    ok $err, 'body before start is illegal';
    is $err->category, 'sequence', 'category sequence';
    is $sv->check({ type => 'http.response.start', status => 200 }), undef, 'legal event after rejection still works';
};

subtest 'http: body after terminal, more=>0 (verbatim probed class)' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http');
    $sv->check({ type => 'http.response.start', status => 200 });
    is $sv->check({ type => 'http.response.body', body => 'x', more => 0 }), undef, 'terminal chunk legal';
    my $err = $sv->check({ type => 'http.response.body', body => 'y' });
    ok $err, 'body after terminal is illegal';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'http: body after terminal via file/fh' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http');
    $sv->check({ type => 'http.response.start', status => 200 });
    is $sv->check({ type => 'http.response.body', file => '/tmp/x' }), undef, 'file body is terminal';
    is $sv->complete, 1, 'complete after file body';
};

subtest 'http: undeclared trailers (verbatim probed class)' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http');
    $sv->check({ type => 'http.response.start', status => 200 }); # no trailers=>1
    $sv->check({ type => 'http.response.body', body => 'x' }); # terminal, no trailers declared -> complete
    my $err = $sv->check({ type => 'http.response.trailers', headers => [] });
    ok $err, 'undeclared trailers is illegal';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'http: trailers before terminal body' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http');
    $sv->check({ type => 'http.response.start', status => 200, trailers => 1 });
    my $err = $sv->check({ type => 'http.response.trailers', headers => [] });
    ok $err, 'trailers before terminal body is illegal';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'http: any event after trailers sent' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http');
    $sv->check({ type => 'http.response.start', status => 200, trailers => 1 });
    $sv->check({ type => 'http.response.body', body => 'x' });
    $sv->check({ type => 'http.response.trailers', headers => [] });
    is $sv->complete, 1, 'complete';
    my $err = $sv->check({ type => 'http.response.body', body => 'extra' });
    ok $err, 'body after trailers sent is illegal';
    is $err->category, 'sequence', 'category sequence';
    $err = $sv->check({ type => 'http.response.start', status => 200 });
    ok $err, 'start after trailers sent is illegal';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'http: extension event rejected when not declared' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http');
    $sv->check({ type => 'http.response.start', status => 200 });
    my $err = $sv->check({ type => 'http.fullflush' });
    ok $err, 'undeclared extension event is illegal';
    is $err->category, 'extension', 'category extension';
};

subtest 'http: extension event legal when declared' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http', extensions => { fullflush => 1 });
    $sv->check({ type => 'http.response.start', status => 200 });
    is $sv->check({ type => 'http.fullflush' }), undef, 'declared extension event legal';
    is $sv->complete, 0, 'fullflush does not advance state';
};

# ==========================================================================
# WebSocket
# ==========================================================================

subtest 'websocket: legal happy path' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'websocket');
    ok $sv->finalize, 'finalize illegal before accept/close';
    is $sv->check({ type => 'websocket.accept' }), undef, 'accept legal';
    is $sv->check({ type => 'websocket.send', text => 'hi' }), undef, 'send legal after accept';
    is $sv->check({ type => 'websocket.close' }), undef, 'close legal';
    is $sv->closed, 1, 'closed true';
    is $sv->finalize, undef, 'finalize legal once closed';
};

subtest 'websocket: send before accept' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'websocket');
    my $err = $sv->check({ type => 'websocket.send', text => 'hi' });
    ok $err, 'send before accept is illegal';
    is $err->category, 'sequence', 'category sequence';
    is $sv->check({ type => 'websocket.accept' }), undef, 'legal event after rejection still works';
};

subtest 'websocket: close before accept is a legal denial and marks closed' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'websocket');
    is $sv->check({ type => 'websocket.close' }), undef, 'close-before-accept is legal';
    is $sv->closed, 1, 'closed true (denial)';
    my $err = $sv->check({ type => 'websocket.accept' });
    ok $err, 'accept after denial close is illegal';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'websocket: send after app-sent close' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'websocket');
    $sv->check({ type => 'websocket.accept' });
    $sv->check({ type => 'websocket.close' });
    my $err = $sv->check({ type => 'websocket.send', text => 'too late' });
    ok $err, 'send after close is illegal';
    is $err->category, 'sequence', 'category sequence';
};

# ==========================================================================
# SSE
# ==========================================================================

subtest 'sse: legal happy stream path' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'sse');
    ok $sv->finalize, 'finalize illegal before start';
    is $sv->check({ type => 'sse.start' }), undef, 'start legal';
    is $sv->check({ type => 'sse.send', data => 'x' }), undef, 'send legal';
    is $sv->check({ type => 'sse.close' }), undef, 'close legal';
    is $sv->closed, 1, 'closed true';
    is $sv->finalize, undef, 'finalize legal once closed';
};

subtest 'sse: legal happy decline path' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'sse');
    is $sv->check({ type => 'sse.http.response.start', status => 404 }), undef, 'decline start legal';
    is $sv->check({ type => 'sse.http.response.body', body => 'x' }), undef, 'decline terminal body legal';
    is $sv->complete, 1, 'complete after decline';
    is $sv->finalize, undef, 'finalize legal once decline complete';
};

subtest 'sse: sse.start twice' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'sse');
    $sv->check({ type => 'sse.start' });
    my $err = $sv->check({ type => 'sse.start' });
    ok $err, 'duplicate sse.start is illegal';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'sse: decline events after sse.start' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'sse');
    $sv->check({ type => 'sse.start' });
    my $err = $sv->check({ type => 'sse.http.response.start', status => 404 });
    ok $err, 'decline after sse.start is illegal';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'sse: stream events after a completed decline' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'sse');
    $sv->check({ type => 'sse.http.response.start', status => 404 });
    $sv->check({ type => 'sse.http.response.body', body => 'x' });
    is $sv->complete, 1, 'decline complete';
    for my $event ({ type => 'sse.start' }, { type => 'sse.send', data => 'x' },
                    { type => 'sse.keepalive', interval => 1 }, { type => 'sse.close' }) {
        my $err = $sv->check($event);
        ok $err, "$event->{type} after completed decline is illegal";
        is $err->category, 'sequence', 'category sequence';
    }
};

subtest 'sse: no-advance-on-error' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'sse');
    $sv->check({ type => 'sse.start' });
    my $err = $sv->check({ type => 'sse.start' }); # duplicate, illegal
    ok $err, 'duplicate rejected';
    is $sv->check({ type => 'sse.send', data => 'ok' }), undef, 'legal event after rejection still works';
};

# ==========================================================================
# Lifespan
# ==========================================================================

subtest 'lifespan: results in the wrong phase' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'lifespan');
    my $err = $sv->check({ type => 'lifespan.shutdown.complete' });
    ok $err, 'shutdown result while in startup phase is illegal';
    is $err->category, 'sequence', 'category sequence';

    is $sv->check({ type => 'lifespan.startup.complete' }), undef, 'startup result in startup phase legal';

    $sv->enter_phase('shutdown');
    $err = $sv->check({ type => 'lifespan.startup.failed' });
    ok $err, 'startup result while in shutdown phase is illegal';
    is $err->category, 'sequence', 'category sequence';

    is $sv->check({ type => 'lifespan.shutdown.complete' }), undef, 'shutdown result in shutdown phase legal';
};

subtest 'lifespan: no-advance-on-error' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'lifespan');
    my $err = $sv->check({ type => 'lifespan.shutdown.complete' });
    ok $err, 'wrong-phase result rejected';
    is $sv->check({ type => 'lifespan.startup.complete' }), undef, 'legal event after rejection still works';
};

subtest 'lifespan: unrecognized/missing type' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'lifespan');
    my $err = $sv->check({ type => 'lifespan.bogus' });
    ok $err, 'bogus lifespan type is illegal';
    is $err->category, 'unknown_type', 'category unknown_type (a real, just wrong, type string)';
    $err = $sv->check({});
    ok $err, 'missing type is illegal';
    is $err->category, 'malformed', 'category malformed (no type key at all)';
};

# ==========================================================================
# Error object shape and never-dies guarantee
# ==========================================================================

subtest 'Error object has message and category accessors' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http');
    my $err = $sv->check({ type => 'http.response.bogus' });
    isa_ok $err, ['PAGI::SendValidation::Error'];
    ok defined($err->message) && length($err->message), 'message is a non-empty string';
    ok defined($err->category) && length($err->category), 'category is a non-empty string';
};

subtest 'check never dies on garbage input' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http');
    my $err = eval { $sv->check(undef) };
    ok !$@, 'undef event does not die' or diag $@;
    ok $err, 'undef event is illegal';
    is $err->category, 'malformed', 'undef event category malformed';
    $err = eval { $sv->check('not a hashref') };
    ok !$@, 'non-hashref event does not die' or diag $@;
    ok $err, 'non-hashref event is illegal';
    is $err->category, 'malformed', 'non-hashref event category malformed';
};

subtest 'websocket/sse: missing type is malformed, not unknown_type' => sub {
    my $ws = PAGI::SendValidation->new(scope_type => 'websocket');
    my $err = $ws->check({});
    ok $err, 'websocket missing type is illegal';
    is $err->category, 'malformed', 'websocket missing type category malformed';

    my $sse = PAGI::SendValidation->new(scope_type => 'sse');
    $err = $sse->check({});
    ok $err, 'sse missing type is illegal';
    is $err->category, 'malformed', 'sse missing type category malformed';
};

subtest 'sse http.fullflush requires the fullflush extension' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'sse');
    $sv->check({ type => 'sse.start' });
    my $err = $sv->check({ type => 'http.fullflush' });
    ok $err, 'undeclared fullflush in sse scope is illegal';
    is $err->category, 'extension', 'category extension';
};

subtest 'sse http.fullflush legal while streaming, keeps streaming state' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'sse', extensions => { fullflush => 1 });
    $sv->check({ type => 'sse.start' });
    is $sv->check({ type => 'http.fullflush' }), undef, 'declared fullflush legal while streaming';
    is $sv->check({ type => 'sse.send', data => 'still streaming' }), undef, 'stream still legal afterward (state unchanged)';
};

subtest 'lifespan rejects a second result for the same phase' => sub {
    for my $pair (['lifespan.startup.complete', 'lifespan.startup.complete'],
                   ['lifespan.startup.complete', 'lifespan.startup.failed'],
                   ['lifespan.startup.failed', 'lifespan.startup.complete']) {
        my ($first, $second) = @$pair;
        my $sv = PAGI::SendValidation->new(scope_type => 'lifespan');
        is $sv->check({ type => $first }), undef, "$first legal as the first startup result";
        my $err = $sv->check({ type => $second });
        ok $err, "$second rejected as a second startup-phase result";
        is $err->category, 'sequence', 'category sequence';
    }
};

subtest 'enter_phase resets the result_sent flag for the new phase' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'lifespan');
    is $sv->check({ type => 'lifespan.startup.complete' }), undef, 'startup result sent';
    $sv->enter_phase('shutdown');
    is $sv->check({ type => 'lifespan.shutdown.complete' }), undef, 'shutdown result legal: fresh phase, flag reset';
    my $err = $sv->check({ type => 'lifespan.shutdown.failed' });
    ok $err, 'second shutdown result rejected';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'new() rejects a non-hashref extensions argument' => sub {
    like dies { PAGI::SendValidation->new(scope_type => 'http', extensions => 'nope') },
        qr/extensions/i, 'croaks naming extensions';
};

subtest 'an Error with an empty message is still boolean-true' => sub {
    my $err = PAGI::SendValidation::Error->new(category => 'sequence', message => '');
    ok $err, 'Error with empty message is truthy';
    if ($err) { pass 'truthy in an if() as well' } else { fail 'truthy in an if() as well' }
};

subtest 'http.fullflush legal in awaiting_trailers state' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'http', extensions => { fullflush => 1 });
    $sv->check({ type => 'http.response.start', status => 200, trailers => 1 });
    $sv->check({ type => 'http.response.body', body => 'x' }); # terminal -> awaiting_trailers
    is $sv->check({ type => 'http.fullflush' }), undef, 'fullflush legal while awaiting declared trailers';
    is $sv->check({ type => 'http.response.trailers', headers => [] }), undef, 'trailers still legal afterward';
};

subtest 'sse.comment legal while streaming, rejected after a completed decline' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'sse');
    $sv->check({ type => 'sse.start' });
    is $sv->check({ type => 'sse.comment', comment => 'hi' }), undef, 'sse.comment legal while streaming';

    my $sv2 = PAGI::SendValidation->new(scope_type => 'sse');
    $sv2->check({ type => 'sse.http.response.start', status => 404 });
    $sv2->check({ type => 'sse.http.response.body', body => 'x' });
    my $err = $sv2->check({ type => 'sse.comment', comment => 'too late' });
    ok $err, 'sse.comment after a completed decline is illegal';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'websocket.keepalive treatment across connecting/accepted/closed' => sub {
    my $sv = PAGI::SendValidation->new(scope_type => 'websocket');
    my $err = $sv->check({ type => 'websocket.keepalive', interval => 1 });
    ok $err, 'keepalive before accept is illegal';
    is $err->category, 'sequence', 'category sequence';

    $sv->check({ type => 'websocket.accept' });
    is $sv->check({ type => 'websocket.keepalive', interval => 1 }), undef, 'keepalive legal once accepted';

    $sv->check({ type => 'websocket.close' });
    $err = $sv->check({ type => 'websocket.keepalive', interval => 1 });
    ok $err, 'keepalive after close is illegal';
    is $err->category, 'sequence', 'category sequence';
};

done_testing;
