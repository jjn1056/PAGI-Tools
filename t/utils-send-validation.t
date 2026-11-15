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

subtest 'http: a body that is not bytes (as PAGI::Server rejects it)' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
    is $sv->check({ type => 'http.response.start', status => 200 }), undef, 'start';
    my $err = $sv->check({ type => 'http.response.body', body => "caf\x{e9} \x{263A}" });
    ok $err, 'a character above 0xFF is refused';
    is $err->category, 'malformed', 'malformed';
    is $err->message, "http.response.body 'body' contains a character above 0xFF (encode it to bytes)", "the server's words";
    is $sv->complete, 0, 'and it changed nothing';
    is $sv->check({ type => 'http.response.body', body => "caf\xE9" }), undef, 'bytes 128-255 are bytes';
};

subtest 'http: a body that is a reference' => sub {
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http');
    $sv->check({ type => 'http.response.start', status => 200 });
    my $err = $sv->check({ type => 'http.response.body', body => [1] });
    ok $err, 'refused: a body is bytes (PAGI Www.pod)';
    is $err && $err->category, 'malformed', 'malformed';
    is $err && $err->message, "http.response.body 'body' must be bytes, not a ARRAY reference", 'names the reference';
};

subtest 'http/1.x: trailers after a content-length (as PAGI::Server rejects them)' => sub {
    my $sends = sub {
        my ($sv) = @_;
        $sv->check({ type => 'http.response.start', status => 200, trailers => 1, headers => [['Content-Length', 3]] });
        $sv->check({ type => 'http.response.body', body => 'abc' });
        return $sv->check({ type => 'http.response.trailers', headers => [] });
    };
    for my $version ('1.1', '1.0') {
        my $err = $sends->(PAGI::Utils::_SendValidation->new(scope_type => 'http', http_version => $version));
        ok $err, "HTTP/$version: refused";
        is $err && $err->category, 'sequence', "HTTP/$version: sequence";
        is $err && $err->message, 'http.response.trailers requires chunked framing (response declared content-length)', "HTTP/$version: the server's words";
    }
    is $sends->(PAGI::Utils::_SendValidation->new(scope_type => 'http', http_version => '2')), undef,
        'HTTP/2 carries trailers after a content-length';
    is $sends->(PAGI::Utils::_SendValidation->new(scope_type => 'http')), undef, 'no version given: not checked';
    my $chunked = PAGI::Utils::_SendValidation->new(scope_type => 'http', http_version => '1.1');
    $chunked->check({ type => 'http.response.start', status => 200, trailers => 1, headers => [] });
    $chunked->check({ type => 'http.response.body', body => 'abc' });
    is $chunked->check({ type => 'http.response.trailers', headers => [] }), undef, 'HTTP/1.1 without a content-length: fine';
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

subtest 'websocket: refusal status comparison is safe and failure does not commit' => sub {
    for my $status ('not-a-status', []) {
        my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'websocket');
        my @warnings;
        my $err = 'check did not return';
        my $died = dies {
            local $SIG{__WARN__} = sub {
                push @warnings, @_;
                die "warning promoted to exception: $_[0]";
            };
            $err = $sv->check({ type => 'http.response.start', status => $status });
        };
        is $died, undef, 'malformed status does not die under a throwing warning handler';
        is \@warnings, [], 'malformed status does not warn';
        like $err, qr/\Ahttp\.response\.start 'status' must be 200 to 599 \(got '/,
            'malformed status fails its field check, as on the server';
    }

    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'websocket');
    my $err = $sv->check({ type => 'http.response.start', status => 299 });
    ok $err, 'numeric status below 300 is rejected';
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

# ==========================================================================
# Event fields (PAGI Www.pod, RFC 9110): checked before the sequence
# ==========================================================================

# The message check gives the last event, after the ones before it pass;
# undef when it passes too. Options go to new.
sub message_for {
    my ($scope_type, $events, %opts) = @_;
    my $sv = PAGI::Utils::_SendValidation->new(scope_type => $scope_type, http_version => '1.1', %opts);
    my @first = @$events;
    my $last  = pop @first;
    for my $event (@first) {
        my $err = $sv->check($event);
        return "an earlier event failed: $err" if $err;
    }
    my $err = $sv->check($last);
    return $err ? $err->message : undef;
}

sub start_with { +{ type => 'http.response.start', status => 200, headers => [@_] } }
sub start_length { start_with(['content-length', $_[0]]) }
sub body_of { +{ type => 'http.response.body', @_ } }

subtest 'a header name is an RFC 9110 token' => sub {
    for my $name ('x-ok', 'X-Ok', "!#\$%&'*+-.^_`|~09AZaz") {
        is message_for(http => [start_with([$name, 'v'])]), undef, "'$name' passes";
    }
    my $token = '(a header name must be an RFC 9110 token)';
    my %fails = (
        ''                  => 'name is empty',
        'x a'               => "name 'x a' contains SP (\\x20) at offset 1 $token",
        'set-cookie:a=b; x' => "name 'set-cookie:a=b; x' contains ':' (\\x3a) at offset 10 $token",
        ':status'           => "name ':status' contains ':' (\\x3a) at offset 0 $token",
        "\x85x"             => "name '\\x85x' contains a non-ASCII byte (\\x85) at offset 0 $token",
        "x\x01y"            => "name 'x\\x01y' contains a control character (\\x01) at offset 1 $token",
        "x\r\ny"            => "name 'x\\x0d\\x0ay' contains CR (\\x0d) at offset 1 $token",
        "x\x{263a}"         => "name 'x\\x{263a}' contains a character above 0xFF (\\x{263a}) at offset 1 $token",
    );
    for my $name (sort keys %fails) {
        is message_for(http => [start_with(['a', 'ok'], [$name, 'v'])]), "http.response.start header 1: $fails{$name}",
            "the message names the event, the index and the problem: " . ($fails{$name} =~ s/ \(a header.*//r);
    }
};

subtest 'a header value is an RFC 9110 field value' => sub {
    for my $value ('', 'v', "a\tb", 'a b', "caf\xE9", "x\xFFy") {
        is message_for(http => [start_with(['x-v', $value])]), undef, 'a value of ' . length($value) . ' bytes passes';
    }
    my %fails = (
        "a\r\nb"     => 'value contains CR (\x0d) at offset 1',
        "a\nb"       => 'value contains LF (\x0a) at offset 1',
        "a\0b"       => 'value contains NUL (\x00) at offset 1',
        "a\x01b"     => 'value contains a control character (\x01) at offset 1',
        "a\x7Fb"     => 'value contains DEL (\x7f) at offset 1',
        ' v'         => 'value starts with SP (\x20); trim it',
        'v '         => 'value ends with SP (\x20); trim it',
        "\tv"        => 'value starts with HTAB (\x09); trim it',
        "ok\x{263a}" => 'value contains a character above 0xFF (\x{263a}) at offset 2 (encode it to bytes)',
    );
    for my $value (sort keys %fails) {
        is message_for(http => [start_with(['a', 'ok'], ['X-V', $value])]), "http.response.start header 1 ('X-V'): $fails{$value}",
            "the message names the header, never the value: $fails{$value}";
    }
    my $secret = message_for(http => [start_with(['x-v', "secret\nmore"])]);
    unlike $secret, qr/secret|more/, 'the value is never shown';
};

subtest 'headers: their shape, and the same rules on every event that carries them' => sub {
    is message_for(http => [{ type => 'http.response.start', status => 200, headers => 'x' }]),
        "http.response.start 'headers' must be an array reference", 'not an array';
    is message_for(http => [start_with(['x'])]), 'http.response.start headers: each header must be a 2-element array reference',
        'not pairs';
    is message_for(http => [start_with([undef, 'v'])]), 'http.response.start headers: header name and value must be defined strings',
        'an undefined name';
    my $cr = "header 0 ('x-v'): value contains CR (\\x0d) at offset 1";
    is message_for(http => [{ type => 'http.response.start', status => 200, trailers => 1 }, body_of(body => 'x'),
        { type => 'http.response.trailers', headers => [['x-v', "a\rb"]] }]), "http.response.trailers $cr", 'trailers';
    is message_for(websocket => [{ type => 'websocket.accept', headers => [['x-v', "a\rb"]] }]), "websocket.accept $cr", 'websocket.accept';
    is message_for(sse => [{ type => 'sse.start', headers => [['x-v', "a\rb"]] }]), "sse.start $cr", 'sse.start';
    is message_for(websocket => [{ type => 'http.response.start', status => 403, headers => [['x-v', "a\rb"]] }]),
        "http.response.start $cr", 'a websocket refusal';
    is message_for(sse => [{ type => 'http.response.start', status => 404, headers => [['x-v', "a\rb"]] }]),
        "http.response.start $cr", 'an sse refusal';
};

subtest 'a status is 200 to 599, written as three digits' => sub {
    is message_for(http => [{ type => 'http.response.start', status => $_ }]), undef, "$_ passes" for 200, '204', 599;
    is message_for(http => [{ type => 'http.response.start' }]), "http.response.start requires 'status' field", 'none';
    for my $status ('abc', '0204', 101, 600, '200.0', -1) {
        is message_for(http => [{ type => 'http.response.start', status => $status }]),
            "http.response.start 'status' must be 200 to 599 (got '$status')", "'$status' fails";
    }
    is message_for(http => [{ type => 'http.response.start', status => undef }]),
        "http.response.start 'status' must be 200 to 599 (got 'undef')", 'undef fails';
    like message_for(http => [{ type => 'http.response.start', status => [200] }]),
        qr/\Ahttp\.response\.start 'status' must be 200 to 599 \(got 'ARRAY\(0x[0-9a-f]+\)'\)\z/, 'a reference fails';
    is message_for(http => [{ type => 'http.response.start', status => " 200\n" }]),
        "http.response.start 'status' must be 200 to 599 (got ' 200\\x0a')", 'the status is shown escaped';
    is message_for(sse => [{ type => 'sse.start', status => 101 }]), "sse.start 'status' must be 200 to 599 (got '101')",
        'sse.start, when it gives one';
    is message_for(sse => [{ type => 'http.response.start', status => 101 }]),
        "http.response.start 'status' must be 200 to 599 (got '101')", 'an sse refusal';
};

subtest 'a response carries one content-length, a decimal number' => sub {
    is message_for(http => [start_length('5')]), undef, '5 passes';
    for my $value ('abc', '-1', '+5', '', '5, 5') {
        is message_for(http => [start_with(['x-a', 1], ['content-length', $value])]),
            "http.response.start header 1 ('content-length'): content-length must be one decimal number", "'$value' fails";
    }
    is message_for(http => [start_with(['content-length', 5], ['x-a', 1], ['Content-Length', 5])]),
        "http.response.start header 2 ('Content-Length'): content-length appears more than once (also header 0)",
        'a second line, equal or not, compared case-insensitively';
    is message_for(sse => [{ type => 'sse.start', headers => [['content-length', 'abc']] }]), undef,
        'not sse.start, which sends no length-framed body';
};

subtest 'the other fields of a response' => sub {
    is message_for(http => [{ type => 'http.response.start', status => 200, trailers => $_ }]),
        "http.response.start 'trailers' must be 0 or 1", "trailers '$_' fails" for 2, 'yes';
    my $start = start_with();
    is message_for(http => [$start, body_of(body => 'x', file => __FILE__)]),
        'http.response.body requires exactly one of body/file/fh (got 2)', 'a body and a file';
    is message_for(http => [$start, body_of(file => __FILE__, offset => -1)]),
        "http.response.body 'offset' must be a non-negative integer", 'offset';
    is message_for(http => [$start, body_of(file => __FILE__, length => 'x')]),
        "http.response.body 'length' must be a non-negative integer", 'length';
    is message_for(http => [$start, body_of(body => 'x', more => 2)]), "http.response.body 'more' must be 0 or 1", 'more';
    is message_for(http => [$start, body_of(body => 'x', more => 1), body_of(file => __FILE__)]),
        'cannot send a file/fh body after inline body bytes', 'a file after inline bytes';
};

subtest 'http/1.x: a body is counted against its content-length' => sub {
    is message_for(http => [start_length(2), body_of(body => 'ok')]), undef, 'the declared length';
    is message_for(http => [start_length(3), body_of(body => 'abcd')]),
        'http.response.body would send 4 bytes, 1 more than the declared content-length (3)', 'over';
    is message_for(http => [start_length(10), body_of(body => 'abcde')]),
        'http.response.body ends the response 5 bytes short of the declared content-length (10)', 'short';
    is message_for(http => [start_length(5), body_of(body => 'abc', more => 1), body_of(body => 'abc', more => 1)]),
        'http.response.body would send 3 bytes, 1 more than the declared content-length (5)', 'chunks add up';
    is message_for(http => [start_with(['Content-Length', 3]), body_of(body => 'abcd')]),
        'http.response.body would send 4 bytes, 1 more than the declared content-length (3)', 'whatever the case of the name';

    my $sv = PAGI::Utils::_SendValidation->new(scope_type => 'http', http_version => '1.1');
    $sv->check(start_length(3));
    my $err = $sv->check(body_of(body => 'abcd'));
    is $err->category, 'sequence', 'a sequence error';
    is $sv->check(body_of(body => 'abc')), undef, 'that changed nothing: the right bytes still go';

    my $size = -s __FILE__;
    is message_for(http => [start_length($size), body_of(file => __FILE__)]), undef, 'a file counts its size';
    is message_for(http => [start_length($size - 10), body_of(file => __FILE__, offset => 10)]), undef, 'less its offset';
    is message_for(http => [start_length(3), body_of(file => __FILE__, length => 4)]),
        'http.response.body would send 4 bytes, 1 more than the declared content-length (3)', 'or its length';
    open my $fh, '<', __FILE__ or die "open: $!";
    is message_for(http => [start_length(3), body_of(fh => $fh, length => 4)]),
        'http.response.body would send 4 bytes, 1 more than the declared content-length (3)', 'an fh with a length';
    is message_for(http => [start_length(3), body_of(fh => $fh)]), undef, 'an fh without one is not counted';
    is message_for(http => [start_length($size + 5), body_of(file => __FILE__, length => $size + 5)]),
        'http.response.body ends the response 5 bytes short of the declared content-length (' . ($size + 5) . ')',
        'a file counts what it holds, not a longer length';
    is message_for(http => [start_length($size + 5), body_of(fh => $fh, length => $size + 5)]),
        'http.response.body ends the response 5 bytes short of the declared content-length (' . ($size + 5) . ')',
        'so does an fh on a file';
    close $fh;

    is message_for(http => [start_length(2), body_of(body => 'abcd')], method => 'HEAD'), undef, 'not for HEAD';
    is message_for(http => [{ %{ start_length(5) }, status => 304 }, body_of(body => '')]), undef, 'nor 304';
    is message_for(http => [start_length(2), body_of(body => 'abcd')], http_version => '2'), undef, 'nor HTTP/2';
    is message_for(websocket => [{ %{ start_length(3) }, status => 403 }, body_of(body => 'abcd')]),
        'http.response.body would send 4 bytes, 1 more than the declared content-length (3)', 'a websocket refusal is counted';
    is message_for(sse => [{ %{ start_length(3) }, status => 404 }, body_of(body => 'ab')]),
        'http.response.body ends the response 1 bytes short of the declared content-length (3)', 'so is an sse refusal';
};

subtest 'websocket: event fields' => sub {
    my $accept = { type => 'websocket.accept' };
    my %fails = (
        'websocket.send requires exactly one of bytes/text (got 0)' => { type => 'websocket.send' },
        'websocket.send requires exactly one of bytes/text (got 2)' => { type => 'websocket.send', bytes => 'a', text => 'b' },
        "websocket.send 'bytes' must be bytes, not a ARRAY reference" => { type => 'websocket.send', bytes => [1] },
        "websocket.send 'bytes' contains a character above 0xFF (encode it to bytes, or send text)"
            => { type => 'websocket.send', bytes => "\x{263a}" },
        "websocket.close 'code' must be a non-negative integer" => { type => 'websocket.close', code => 'abc' },
        "websocket.close 'reason' must be at most 123 bytes as UTF-8 (got 124)" => { type => 'websocket.close', reason => 'r' x 124 },
        "websocket.close 'reason' must be a string" => { type => 'websocket.close', reason => [] },
        "websocket.keepalive requires 'interval' field" => { type => 'websocket.keepalive' },
        "websocket.keepalive 'interval' must be a non-negative number" => { type => 'websocket.keepalive', interval => -1 },
        "websocket.keepalive 'timeout' must be a non-negative number"
            => { type => 'websocket.keepalive', interval => 1, timeout => 'x' },
    );
    is message_for(websocket => [$accept, $fails{$_}]), $_, $_ for sort keys %fails;
    is message_for(websocket => [$accept, { type => 'websocket.close', reason => "\x{e9}" x 61 }]), undef,
        'a reason of 122 bytes as UTF-8 passes';
    is message_for(websocket => [{ type => 'http.response.start', status => 299 }]),
        'WebSocket refusal status must be 300 or above (got 299)', 'a refusal status below 300';
    is message_for(websocket => [{ type => 'http.response.start', status => 101 }]),
        "http.response.start 'status' must be 200 to 599 (got '101')", '101 is not a status a response sends';
};

subtest 'sse: event fields' => sub {
    my $start = { type => 'sse.start' };
    my %fails = (
        "sse.send requires 'data' field"                  => { type => 'sse.send' },
        "sse.send 'data' must be a string"                => { type => 'sse.send', data => [] },
        "sse.send 'event' must not contain newline characters" => { type => 'sse.send', data => 'd', event => "a\nb" },
        "sse.send 'id' must not contain newline characters"    => { type => 'sse.send', data => 'd', id => "a\rb" },
        "sse.send 'retry' must be a non-negative integer" => { type => 'sse.send', data => 'd', retry => -1 },
        "sse.comment requires 'comment' field"            => { type => 'sse.comment' },
        "sse.comment 'comment' must be a string"          => { type => 'sse.comment', comment => [] },
        "sse.keepalive requires 'interval' field"         => { type => 'sse.keepalive' },
        "sse.keepalive 'comment' must be a UTF-8-encodable string" => { type => 'sse.keepalive', interval => 1, comment => [] },
        "sse.close 'reason' must be a string"             => { type => 'sse.close', reason => [] },
    );
    is message_for(sse => [$start, $fails{$_}]), $_, $_ for sort keys %fails;
    is message_for(sse => [{ type => 'sse.start', status => 'abc' }]), "sse.start 'status' must be 200 to 599 (got 'abc')",
        'sse.start status';
    is message_for(sse => [$start, { type => 'sse.keepalive', interval => 1, comment => "caf\x{e9}" }]), undef,
        'a keepalive comment of characters passes';
};

subtest 'lifespan: a failure message is a string' => sub {
    is message_for(lifespan => [{ type => 'lifespan.startup.failed', message => [] }]),
        "lifespan.startup.failed 'message' must be a string", 'a reference fails';
    is message_for(lifespan => [{ type => 'lifespan.startup.failed', message => 'no db' }]), undef, 'a string passes';
};

subtest 'fields are checked before the sequence' => sub {
    is message_for(http => [start_with(), { type => 'http.response.start', status => 999 }]),
        "http.response.start 'status' must be 200 to 599 (got '999')", 'a bad duplicate start: its field';
    is message_for(http => [body_of(body => 'x', more => 2)]), "http.response.body 'more' must be 0 or 1",
        'a bad body before the start: its field';
    is message_for(websocket => [{ type => 'websocket.accept' }, { type => 'http.response.start', status => 101 }]),
        "http.response.start 'status' must be 200 to 599 (got '101')", 'a bad refusal after accept: its field';
};

done_testing;
