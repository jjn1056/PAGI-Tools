use strict;
use warnings;
use Test2::V0;
use PAGI::Utils::_SendValidation;

# ==========================================================================
# HTTP
# ==========================================================================

subtest 'http: legal happy path (no trailers) advances to complete' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
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
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
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
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
    my $err = $sv->check({ status => 200 });
    ok $err, 'missing type is illegal';
    is $err->category, 'malformed', 'category malformed (not unknown_type: no type to even evaluate)';
    is $sv->started, 0, 'illegal event did not advance state';
    is $sv->check({ type => 'http.response.start', status => 200 }), undef, 'legal event after rejection still works';
};

subtest 'http: unrecognized event type http.response.bogus (verbatim probed class)' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
    my $err = $sv->check({ type => 'http.response.bogus' });
    ok $err, 'bogus type is illegal';
    is $err->category, 'unknown_type', 'category unknown_type';
    is $sv->check({ type => 'http.response.start', status => 200 }), undef, 'legal event after rejection still works';
};

subtest 'http: duplicate http.response.start (verbatim probed class)' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
    is $sv->check({ type => 'http.response.start', status => 200 }), undef, 'first start legal';
    my $err = $sv->check({ type => 'http.response.start', status => 200 });
    ok $err, 'duplicate start is illegal';
    is $err->category, 'sequence', 'category sequence';
    is $sv->check({ type => 'http.response.body', body => 'ok' }), undef, 'legal event after rejection still works';
};

subtest 'http: body before start' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
    my $err = $sv->check({ type => 'http.response.body', body => 'x' });
    ok $err, 'body before start is illegal';
    is $err->category, 'sequence', 'category sequence';
    is $sv->check({ type => 'http.response.start', status => 200 }), undef, 'legal event after rejection still works';
};

subtest 'http: body after terminal, more=>0 (verbatim probed class)' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
    $sv->check({ type => 'http.response.start', status => 200 });
    is $sv->check({ type => 'http.response.body', body => 'x', more => 0 }), undef, 'terminal chunk legal';
    my $err = $sv->check({ type => 'http.response.body', body => 'y' });
    ok $err, 'body after terminal is illegal';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'http: body after terminal via file/fh' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
    $sv->check({ type => 'http.response.start', status => 200 });
    is $sv->check({ type => 'http.response.body', file => '/tmp/x' }), undef, 'file body is terminal';
    is $sv->complete, 1, 'complete after file body';
};

subtest 'http: undeclared trailers (verbatim probed class)' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
    $sv->check({ type => 'http.response.start', status => 200 }); # no trailers=>1
    $sv->check({ type => 'http.response.body', body => 'x' }); # terminal, no trailers declared -> complete
    my $err = $sv->check({ type => 'http.response.trailers', headers => [] });
    ok $err, 'undeclared trailers is illegal';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'http: trailers before terminal body' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
    $sv->check({ type => 'http.response.start', status => 200, trailers => 1 });
    my $err = $sv->check({ type => 'http.response.trailers', headers => [] });
    ok $err, 'trailers before terminal body is illegal';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'http: any event after trailers sent' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
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
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
    $sv->check({ type => 'http.response.start', status => 200 });
    my $err = $sv->check({ type => 'http.fullflush' });
    ok $err, 'undeclared extension event is illegal';
    is $err->category, 'extension', 'category extension';
};

subtest 'http: extension event legal when declared' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http', extensions => { fullflush => 1 });
    $sv->check({ type => 'http.response.start', status => 200 });
    is $sv->check({ type => 'http.fullflush' }), undef, 'declared extension event legal';
    is $sv->complete, 0, 'fullflush does not advance state';
};

# ==========================================================================
# WebSocket
# ==========================================================================

subtest 'websocket: legal happy path' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'websocket');
    ok $sv->finalize, 'finalize illegal before accept/close';
    is $sv->check({ type => 'websocket.accept' }), undef, 'accept legal';
    is $sv->check({ type => 'websocket.send', text => 'hi' }), undef, 'send legal after accept';
    is $sv->check({ type => 'websocket.close' }), undef, 'close legal';
    is $sv->closed, 1, 'closed true';
    is $sv->finalize, undef, 'finalize legal once closed';
};

subtest 'websocket: send before accept' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'websocket');
    my $err = $sv->check({ type => 'websocket.send', text => 'hi' });
    ok $err, 'send before accept is illegal';
    is $err->category, 'sequence', 'category sequence';
    is $sv->check({ type => 'websocket.accept' }), undef, 'legal event after rejection still works';
};

subtest 'websocket: close before accept is a sequence error' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'websocket');
    my $err = $sv->check({ type => 'websocket.close', code => 1008 });
    like $err, qr/before websocket\.accept/, 'close-before-accept is rejected';
    is $err ? $err->category : undef, 'sequence', 'category sequence';
    is $sv->check({ type => 'websocket.accept' }), undef,
        'rejected close did not prevent a later accept';
};

subtest 'websocket: send after app-sent close' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'websocket');
    $sv->check({ type => 'websocket.accept' });
    $sv->check({ type => 'websocket.close' });
    my $err = $sv->check({ type => 'websocket.send', text => 'too late' });
    ok $err, 'send after close is illegal';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'websocket: HTTP response events refuse the handshake before accept' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'websocket', extensions => {});
    is $sv->check({ type => 'http.response.start', status => 401, headers => [] }), undef, 'start accepted';
    ok !$sv->complete, 'not complete after start';
    is $sv->check({ type => 'http.response.body', body => 'more', more => 1 }), undef, 'more keeps refusing';
    is $sv->check({ type => 'http.response.body', body => 'done' }), undef, 'terminal';
    ok $sv->complete, 'complete after terminal';
    ok !$sv->closed, 'a refusal is not websocket.close';
    is $sv->finalize, undef, 'completed refusal finalizes';
    like $sv->check({ type => 'websocket.accept' }), qr/refusal already complete/, 'nothing after completion';
};

subtest 'websocket: refusal status must be 300 or above and failure does not commit' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'websocket');
    my $err = $sv->check({ type => 'http.response.start', status => 200 });
    ok $err, '2xx refusal is rejected';
    is $err->category, 'sequence', 'status failure is a sequence error';
    is $sv->check({ type => 'http.response.start', status => 300 }), undef,
        'boundary status is accepted after the rejection';
    is $sv->check({ type => 'http.response.body', body => '' }), undef, 'refusal completes';
};

subtest 'websocket: HTTP events after accept fail without changing accepted state' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'websocket', extensions => { fullflush => 1 });
    is $sv->check({ type => 'websocket.accept' }), undef, 'accept';
    for my $event (
        { type => 'http.response.start', status => 401 },
        { type => 'http.response.body', body => 'no' },
        { type => 'http.response.trailers', headers => [] },
        { type => 'http.fullflush' },
    ) {
        my $err = $sv->check($event);
        like $err, qr/after websocket\.accept/, "$event->{type} rejected after accept";
        is $err->category, 'sequence', 'category sequence';
    }
    is $sv->check({ type => 'websocket.send', text => 'still accepted' }), undef,
        'rejected HTTP events did not change accepted state';
};

subtest 'websocket: removed response event names are unknown types' => sub {
    for my $type (qw(websocket.http.response.start websocket.http.response.body)) {
        my $sv = PAGI::Utils::_SendValidation->new(
            scope_type => 'websocket', extensions => { 'websocket.http.response' => {} },
        );
        my $err = $sv->check({ type => $type, status => 401, body => 'no' });
        is $err ? $err->category : undef, 'unknown_type',
            "$type is unknown even with the former extension";
        is $sv->check({ type => 'websocket.accept' }), undef, 'unknown event did not change state';
    }
};

# ==========================================================================
# SSE
# ==========================================================================

subtest 'sse: legal happy stream path' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'sse');
    ok $sv->finalize, 'finalize illegal before start';
    is $sv->check({ type => 'sse.start' }), undef, 'start legal';
    is $sv->check({ type => 'sse.send', data => 'x' }), undef, 'send legal';
    is $sv->check({ type => 'sse.close' }), undef, 'close legal';
    is $sv->closed, 1, 'closed true';
    is $sv->finalize, undef, 'finalize legal once closed';
};

subtest 'sse: HTTP response events refuse the stream before start, including status 200' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'sse');
    is $sv->check({ type => 'http.response.start', status => 200, headers => [] }), undef, 'start';
    is $sv->check({ type => 'http.response.body', body => 'nope' }), undef, 'terminal';
    ok $sv->complete, 'complete';
    is $sv->finalize, undef, 'completed refusal finalizes';
};

subtest 'sse: sse.start twice' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'sse');
    $sv->check({ type => 'sse.start' });
    my $err = $sv->check({ type => 'sse.start' });
    ok $err, 'duplicate sse.start is illegal';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'sse: HTTP events after sse.start fail without changing streaming state' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'sse', extensions => { fullflush => 1 });
    is $sv->check({ type => 'sse.start', status => 200 }), undef, 'start stream';
    for my $event (
        { type => 'http.response.start', status => 404 },
        { type => 'http.response.body', body => 'no' },
        { type => 'http.response.trailers', headers => [] },
    ) {
        my $err = $sv->check($event);
        like $err, qr/after sse\.start/, "$event->{type} rejected after sse.start";
        is $err->category, 'sequence', 'category sequence';
    }
    is $sv->check({ type => 'sse.send', data => 'still streaming' }), undef,
        'rejected HTTP events did not change streaming state';
};

subtest 'sse: removed response event names are unknown types' => sub {
    for my $type (qw(sse.http.response.start sse.http.response.body)) {
        my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'sse');
        my $err = $sv->check({ type => $type, status => 404, body => 'no' });
        is $err ? $err->category : undef, 'unknown_type', "$type is unknown";
        is $sv->check({ type => 'sse.start' }), undef, 'unknown event did not change state';
    }
};

subtest 'sse: no-advance-on-error' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'sse');
    $sv->check({ type => 'sse.start' });
    my $err = $sv->check({ type => 'sse.start' }); # duplicate, illegal
    ok $err, 'duplicate rejected';
    is $sv->check({ type => 'sse.send', data => 'ok' }), undef, 'legal event after rejection still works';
};

for my $case (
    { scope => 'websocket', status => 401 },
    { scope => 'sse',       status => 200 },
) {
    my $scope  = $case->{scope};
    my $status = $case->{status};

    subtest "$scope refusal: file and fh bodies are terminal" => sub {
        for my $body ({ file => '/tmp/refusal-body' }, { fh => 'opaque-handle' }) {
            my $sv = PAGI::Utils::_SendValidation->new(scope_type => $scope);
            is $sv->check({ type => 'http.response.start', status => $status }), undef, 'start';
            is $sv->check({ type => 'http.response.body', %$body, more => 1 }), undef,
                (exists $body->{file} ? 'file' : 'fh') . ' body accepted';
            ok $sv->complete, 'file/fh overrides more and completes the refusal';
        }
    };

    subtest "$scope refusal: declared trailers are required after the terminal body" => sub {
        my $sv = PAGI::Utils::_SendValidation->new(scope_type => $scope);
        is $sv->check({ type => 'http.response.start', status => $status, trailers => 1 }), undef,
            'start declaring trailers';
        my $protocol_type = $scope eq 'websocket' ? 'websocket.accept' : 'sse.start';
        my $err = $sv->check({ type => $protocol_type });
        like $err, qr/after http\.response\.start/, "$protocol_type rejected once refusal started";
        $err = $sv->check({ type => 'http.response.trailers', headers => [] });
        like $err, qr/body is not complete/, 'early trailers rejected';
        is $err->category, 'sequence', 'category sequence';
        is $sv->check({ type => 'http.response.body', body => 'done' }), undef,
            'terminal body accepted after rejected early trailers';
        ok !$sv->complete, 'body alone does not complete a response that declared trailers';
        like $sv->finalize, qr/awaiting declared http\.response\.trailers/,
            'finalize reports the missing declared trailers';
        $err = $sv->check({ type => 'http.response.body', body => 'extra' });
        like $err, qr/body already terminal/, 'body after terminal is rejected while awaiting trailers';
        is $sv->check({ type => 'http.response.trailers', headers => [] }), undef,
            'declared trailers complete the refusal after rejected extra body';
        ok $sv->complete, 'complete after trailers';
    };

    subtest "$scope refusal: undeclared trailers and duplicate start do not advance state" => sub {
        my $sv = PAGI::Utils::_SendValidation->new(scope_type => $scope);
        my $err = $sv->check({ type => 'http.response.trailers', headers => [] });
        like $err, qr/before http\.response\.start/, 'trailers before start rejected';
        is $sv->check({ type => 'http.response.start', status => $status }), undef,
            'start remains legal after rejected trailers';
        $err = $sv->check({ type => 'http.response.start', status => $status });
        like $err, qr/duplicate http\.response\.start/, 'duplicate start rejected';
        $err = $sv->check({ type => 'http.response.trailers', headers => [] });
        like $err, qr/trailers were not declared/, 'undeclared trailers rejected';
        is $sv->check({ type => 'http.response.body', body => 'done' }), undef,
            'terminal body remains legal after both rejected events';
        ok $sv->complete, 'refusal completes normally';
    };

    subtest "$scope refusal: http.fullflush follows the HTTP extension rule" => sub {
        my $without = PAGI::Utils::_SendValidation->new(scope_type => $scope);
        is $without->check({ type => 'http.response.start', status => $status }), undef, 'start without extension';
        my $err = $without->check({ type => 'http.fullflush' });
        is $err->category, 'extension', 'fullflush without extension rejected';
        is $without->check({ type => 'http.response.body', body => 'done' }), undef,
            'extension error did not change refusal state';

        my $with = PAGI::Utils::_SendValidation->new(
            scope_type => $scope, extensions => { fullflush => 1 },
        );
        is $with->check({ type => 'http.response.start', status => $status }), undef, 'start with extension';
        is $with->check({ type => 'http.fullflush' }), undef, 'declared fullflush accepted while refusing';
        is $with->check({ type => 'http.response.body', body => 'done' }), undef,
            'fullflush did not change refusal state';
    };
}

# ==========================================================================
# Lifespan
# ==========================================================================

subtest 'lifespan: results in the wrong phase' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'lifespan');
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
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'lifespan');
    my $err = $sv->check({ type => 'lifespan.shutdown.complete' });
    ok $err, 'wrong-phase result rejected';
    is $sv->check({ type => 'lifespan.startup.complete' }), undef, 'legal event after rejection still works';
};

subtest 'lifespan: unrecognized/missing type' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'lifespan');
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
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
    my $err = $sv->check({ type => 'http.response.bogus' });
    isa_ok $err, ['PAGI::Utils::_SendValidation::Error'];
    ok defined($err->message) && length($err->message), 'message is a non-empty string';
    ok defined($err->category) && length($err->category), 'category is a non-empty string';
};

subtest 'check never dies on garbage input' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
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
    my $ws = PAGI::Utils::_SendValidation->new(scope_type => 'websocket');
    my $err = $ws->check({});
    ok $err, 'websocket missing type is illegal';
    is $err->category, 'malformed', 'websocket missing type category malformed';

    my $sse = PAGI::Utils::_SendValidation->new(scope_type => 'sse');
    $err = $sse->check({});
    ok $err, 'sse missing type is illegal';
    is $err->category, 'malformed', 'sse missing type category malformed';
};

subtest 'sse http.fullflush requires the fullflush extension' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'sse');
    $sv->check({ type => 'sse.start' });
    my $err = $sv->check({ type => 'http.fullflush' });
    ok $err, 'undeclared fullflush in sse scope is illegal';
    is $err->category, 'extension', 'category extension';
};

subtest 'sse http.fullflush legal while streaming, keeps streaming state' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'sse', extensions => { fullflush => 1 });
    $sv->check({ type => 'sse.start' });
    is $sv->check({ type => 'http.fullflush' }), undef, 'declared fullflush legal while streaming';
    is $sv->check({ type => 'sse.send', data => 'still streaming' }), undef, 'stream still legal afterward (state unchanged)';
};

subtest 'lifespan rejects a second result for the same phase' => sub {
    for my $pair (['lifespan.startup.complete', 'lifespan.startup.complete'],
                   ['lifespan.startup.complete', 'lifespan.startup.failed'],
                   ['lifespan.startup.failed', 'lifespan.startup.complete']) {
        my ($first, $second) = @$pair;
        my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'lifespan');
        is $sv->check({ type => $first }), undef, "$first legal as the first startup result";
        my $err = $sv->check({ type => $second });
        ok $err, "$second rejected as a second startup-phase result";
        is $err->category, 'sequence', 'category sequence';
    }
};

subtest 'enter_phase resets the result_sent flag for the new phase' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'lifespan');
    is $sv->check({ type => 'lifespan.startup.complete' }), undef, 'startup result sent';
    $sv->enter_phase('shutdown');
    is $sv->check({ type => 'lifespan.shutdown.complete' }), undef, 'shutdown result legal: fresh phase, flag reset';
    my $err = $sv->check({ type => 'lifespan.shutdown.failed' });
    ok $err, 'second shutdown result rejected';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'new() rejects a non-hashref extensions argument' => sub {
    like dies { PAGI::Utils::_SendValidation->new(scope_type => 'http', extensions => 'nope') },
        qr/extensions/i, 'croaks naming extensions';
};

subtest 'an Error with an empty message is still boolean-true' => sub {
    my $err = PAGI::Utils::_SendValidation::Error->new(category => 'sequence', message => '');
    ok $err, 'Error with empty message is truthy';
    if ($err) { pass 'truthy in an if() as well' } else { fail 'truthy in an if() as well' }
};

subtest 'http.fullflush legal in awaiting_trailers state' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http', extensions => { fullflush => 1 });
    $sv->check({ type => 'http.response.start', status => 200, trailers => 1 });
    $sv->check({ type => 'http.response.body', body => 'x' }); # terminal -> awaiting_trailers
    is $sv->check({ type => 'http.fullflush' }), undef, 'fullflush legal while awaiting declared trailers';
    is $sv->check({ type => 'http.response.trailers', headers => [] }), undef, 'trailers still legal afterward';
};

subtest 'sse.comment legal while streaming, rejected after a completed refusal' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'sse');
    $sv->check({ type => 'sse.start' });
    is $sv->check({ type => 'sse.comment', comment => 'hi' }), undef, 'sse.comment legal while streaming';

    my $sv2 = PAGI::Utils::_SendValidation->new(scope_type => 'sse');
    $sv2->check({ type => 'http.response.start', status => 404 });
    $sv2->check({ type => 'http.response.body', body => 'x' });
    my $err = $sv2->check({ type => 'sse.comment', comment => 'too late' });
    ok $err, 'sse.comment after a completed refusal is illegal';
    is $err->category, 'sequence', 'category sequence';
};

subtest 'websocket.keepalive treatment across connecting/accepted/closed' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'websocket');
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
