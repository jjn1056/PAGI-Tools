use strict;
use warnings;
use utf8;

use File::Spec;
use File::Temp qw(tempdir);
use Future;
use Test2::V0;

use lib 'lib';
use PAGI::Response qw(response);
use PAGI::Response::File;
use PAGI::Response::File::Plan;
use PAGI::Routing::HeadBoundary;

{
    package T::ConfigurableFile;
    use parent 'PAGI::Response::File';

    sub select_path {
        my ($self, $path) = @_;
        die "configured File path must be a nonempty scalar\n"
            unless defined($path) && !ref($path) && length($path);
        $self->{_path} = $path;
        return $self;
    }
}

sub http_scope {
    my (%changes) = @_;
    return {
        type => 'http', method => 'GET', path => '/request-path-is-not-a-file',
        raw_path => '/request-path-is-not-a-file', root_path => '', headers => [],
        %changes,
    };
}

sub receive {
    return sub {
        return Future->done({
            type => 'http.request', body => '', more => 0,
        });
    };
}

sub write_file {
    my ($path, $contents) = @_;
    open my $fh, '>', $path or die "cannot create $path: $!";
    print {$fh} $contents;
    close $fh or die "cannot close $path: $!";
    return;
}

sub run_response {
    my ($response, $scope) = @_;
    my @events;
    $response->to_app->(
        $scope // http_scope(), receive(),
        sub { push @events, $_[0]; return Future->done },
    )->get;
    return \@events;
}

sub event_header {
    my ($event, $name) = @_;
    my @values = map { $_->[1] }
        grep { lc($_->[0]) eq lc($name) } @{$event->{headers} // []};
    return wantarray ? @values : $values[0];
}

subtest 'construction validates configuration but defers all file inspection' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $late = File::Spec->catfile($root, 'late.txt');

    my $response = response('File', $late);
    isa_ok($response, ['PAGI::Response::File', 'PAGI::Response']);
    ok(!$response->is_buffered, 'File explicitly reports unbuffered delivery');
    like(dies { $response->body }, qr/File response.*body/i,
        'File does not expose buffered body bytes');

    write_file($late, 'created after construction');
    my $events = run_response($response);
    is($events->[0]{status}, 200,
        'a path created after construction succeeds at invocation');
    is($events->[1]{file}, $late,
        'the server receives the trusted path selected at construction');
    ok(!exists $events->[1]{fh},
        'the application does not open a long-lived filehandle');

    my $missing = File::Spec->catfile($root, 'missing.txt');
    my $missing_response = response('File', $missing);
    my @missing_events;
    like(dies {
        $missing_response->to_app->(
            http_scope(), receive(),
            sub { push @missing_events, $_[0]; Future->done },
        )->get;
    }, qr/(?:inspect|regular readable).*selected file/i,
        'a missing selected path fails during request preflight');
    is(\@missing_events, [],
        'missing-path preflight fails before response start');

    my $directory_response = response('File', $root);
    my @directory_events;
    like(dies {
        $directory_response->to_app->(
            http_scope(), receive(),
            sub { push @directory_events, $_[0]; Future->done },
        )->get;
    }, qr/regular readable.*selected file/i,
        'a selected directory is not treated as a file');
    is(\@directory_events, [],
        'non-file preflight fails before response start');

    my $unreadable = File::Spec->catfile($root, 'unreadable.txt');
    write_file($unreadable, 'private');
    chmod 0000, $unreadable or die "cannot make $unreadable unreadable: $!";
    if (-r $unreadable) {
        pass('runtime privileges prevent a genuine unreadable-file assertion');
    } else {
        my @events;
        like(dies {
            response('File', $unreadable)->to_app->(
                http_scope(), receive(),
                sub { push @events, $_[0]; Future->done },
            )->get;
        }, qr/regular readable.*selected file/i,
            'an unreadable selected path fails during preflight');
        is(\@events, [], 'unreadable preflight emits no response start');
    }
    chmod 0600, $unreadable or die "cannot restore $unreadable: $!";
};

subtest 'File validates option shapes without consulting the filesystem' => sub {
    for my $case (
        ['missing path', sub { PAGI::Response::File->new() }, qr/requires.*path/i],
        ['undefined path', sub { response('File', undef) }, qr/path.*defined.*nonempty.*string/i],
        ['empty path', sub { response('File', '') }, qr/path.*defined.*nonempty.*string/i],
        ['reference path', sub { response('File', []) }, qr/path.*defined.*nonempty.*string/i],
        ['NUL path', sub { response('File', "bad\0path") }, qr/path.*NUL/i],
        ['odd options', sub { response('File', '/absent', 'offset') }, qr/name\/value pairs/i],
        ['unknown option', sub { response('File', '/absent', mystery => 1) }, qr/unknown.*mystery/i],
        ['duplicate option', sub { response('File', '/absent', offset => 1, offset => 2) }, qr/duplicate.*offset/i],
        ['negative offset', sub { response('File', '/absent', offset => -1) }, qr/offset.*nonnegative integer/i],
        ['fractional length', sub { response('File', '/absent', length => 1.5) }, qr/length.*nonnegative integer/i],
        ['reference range flag', sub { response('File', '/absent', handle_ranges => []) }, qr/handle_ranges.*boolean/i],
        ['nonboolean inline', sub { response('File', '/absent', inline => 2) }, qr/inline.*boolean/i],
        ['reference filename', sub { response('File', '/absent', filename => []) }, qr/filename.*scalar/i],
        ['unsafe filename', sub { response('File', '/absent', filename => "x\r\ny") }, qr/filename.*control/i],
        ['undefined etag', sub { response('File', '/absent', etag => undef) }, qr/etag/i],
        ['reference etag', sub { response('File', '/absent', etag => {}) }, qr/etag/i],
        ['invalid entity tag', sub { response('File', '/absent', etag => 'release-1') }, qr/entity.?tag/i],
    ) {
        my ($label, $code, $error) = @$case;
        like(dies { $code->() }, $error, "$label is rejected at construction");
    }

    ok(response('File', '/absent', offset => 0, length => 0),
        'zero-valued window shapes are accepted without stat');
    ok(response('File', '/absent', etag => 0),
        'false disables automatic ETag without stat');
    ok(response('File', '/absent', etag => 1),
        'true requests automatic ETag without stat');
    ok(response('File', '/absent', etag => 'W/"release-1"'),
        'a validated explicit entity tag is accepted without stat');
};

subtest 'full files and configured windows have authoritative logical metadata' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($root, 'large.bin');
    write_file($path, 'x' x 70_000);

    my $full = run_response(response('File', $path));
    is($full->[0]{status}, 200, 'a complete file is a 200 representation');
    is(event_header($full->[0], 'content-length'), 70_000,
        'full response owns the complete file length');
    ok(!defined event_header($full->[0], 'content-range'),
        'full response does not advertise a storage range');
    is($full->[1], {
        type => 'http.response.body', file => $path,
    }, 'full response hands one whole-file event to the server');

    my $window = run_response(response('File',
        $path, offset => 1024, length => 65_536,
    ));
    is($window->[0]{status}, 200,
        'a configured physical window is still a complete 200 representation');
    is(event_header($window->[0], 'content-length'), 65_536,
        'window Content-Length is its logical representation length');
    ok(!defined event_header($window->[0], 'content-range'),
        'configured storage offset is not disclosed as Content-Range');
    is($window->[1], {
        type => 'http.response.body', file => $path,
        offset => 1024, length => 65_536,
    }, 'window event carries the exact physical offset and length');

    for my $case (
        ['offset beyond file', response('File', $path, offset => 70_001)],
        ['window beyond file', response('File', $path, offset => 69_999, length => 2)],
    ) {
        my ($label, $invalid) = @$case;
        my @events;
        like(dies {
            $invalid->to_app->(
                http_scope(), receive(),
                sub { push @events, $_[0]; Future->done },
            )->get;
        }, qr/(?:offset|window).*file size/i,
            "$label is rejected during request preflight");
        is(\@events, [], "$label emits no response start");
    }
};

subtest 'calculated fields and range status cannot acquire competing owners' => sub {
    for my $name ('Content-Length', 'content-range', 'ETag') {
        like(dies {
            response('File', '/absent', headers => [$name => 'caller']);
        }, qr/File response.*own.*\Q$name\E/i,
            "$name is rejected in constructor headers");
    }

    my $response = response('File', '/absent');
    for my $name ('Content-Length', 'Content-Range', 'ETag') {
        like(dies { $response->header($name => 'caller') }, qr/File response.*own/i,
            "$name is also rejected by later header mutation");
    }
    like(dies { response('File', '/absent', status => 206) }, qr/206.*range plan/i,
        'construction cannot claim partial content without a request plan');
    like(dies { $response->status(206) }, qr/206.*range plan/i,
        'later status mutation cannot claim unplanned partial content');

    my $root = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($root, 'mutated.txt');
    write_file($path, 'mutation');
    my $through_headers = response('File', $path);
    $through_headers->headers->add('ETag', '"caller"');
    my @events;
    like(dies {
        $through_headers->to_app->(
            http_scope(), receive(),
            sub { push @events, $_[0]; Future->done },
        )->get;
    }, qr/File response.*own.*ETag/i,
        'direct Headers mutation cannot install a competing ETag');
    is(\@events, [],
        'late calculated-header conflict is rejected before response start');

    my $framed = run_response(response('File',
        $path, headers => ['Transfer-Encoding' => 'chunked'],
    ));
    ok(!defined event_header($framed->[0], 'transfer-encoding'),
        'File removes caller Transfer-Encoding before calculating length');
    is(event_header($framed->[0], 'content-length'), length('mutation'),
        'File retains its authoritative framing length');
};

subtest 'MIME, disposition, ETag, conditionals, and range arithmetic share one plan' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $json = File::Spec->catfile($root, 'report.json');
    write_file($json, '0123456789');

    my $named = run_response(response('File',
        $json, filename => 'monthly "report".json',
    ));
    is(event_header($named->[0], 'content-type'), 'application/json',
        'known suffix selects the shared MIME type');
    is(event_header($named->[0], 'content-disposition'),
        'attachment; filename="monthly \\"report\\".json"',
        'filename defaults to a safely quoted attachment');

    my $unicode = run_response(response('File', $json, filename => 'résumé.pdf'));
    my $disposition = event_header($unicode->[0], 'content-disposition');
    is($disposition, "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf",
        'non-ASCII download filename is emitted as UTF-8 extended value');
    ok(!utf8::is_utf8($disposition), 'wire disposition is a byte string');

    my $inline = run_response(response('File', $json, inline => 1));
    is(event_header($inline->[0], 'content-disposition'), 'inline',
        'inline without a filename still emits an inline disposition');
    my $inline_named = run_response(response('File',
        $json, inline => 1, filename => 'report.json',
    ));
    is(event_header($inline_named->[0], 'content-disposition'),
        'inline; filename="report.json"',
        'inline filename retains both disposition instructions');

    my $no_etag = run_response(response('File', $json, etag => 0));
    ok(!defined event_header($no_etag->[0], 'etag'),
        'false ETag policy omits the calculated field');
    my $explicit = run_response(response('File', $json, etag => '"release-1"'));
    is(event_header($explicit->[0], 'etag'), '"release-1"',
        'explicit validated ETag is retained');

    my $first_window = response('File', $json, offset => 0, length => 6);
    my $second_window = response('File', $json, offset => 1, length => 6);
    my $first_full = run_response($first_window);
    my $second_full = run_response($second_window);
    my $first_tag = event_header($first_full->[0], 'etag');
    my $second_tag = event_header($second_full->[0], 'etag');
    like($first_tag, qr/\A"[0-9a-f]{32}"\z/,
        'automatic ETag is a valid strong entity tag');
    isnt($first_tag, $second_tag,
        'two logical windows of one backing file have distinct ETags');

    my $partial = run_response(
        $first_window,
        http_scope(headers => [['range', 'bytes=1-3']]),
    );
    is($partial->[0]{status}, 206, 'closed logical range produces 206');
    is(event_header($partial->[0], 'content-range'), 'bytes 1-3/6',
        'Content-Range is measured inside the logical window');
    is(event_header($partial->[0], 'content-length'), 3,
        'partial Content-Length is the logical selection length');
    is(event_header($partial->[0], 'etag'), $first_tag,
        'a client subrange retains its complete-window ETag');
    is($partial->[1], {
        type => 'http.response.body', file => $json,
        offset => 1, length => 3,
    }, 'client logical offset is added to the physical window offset');

    my $not_modified = run_response(
        $first_window,
        http_scope(headers => [['if-none-match', $first_tag]]),
    );
    is($not_modified, [
        {
            type => 'http.response.start', status => 304,
            headers => [['etag', $first_tag]],
        },
        { type => 'http.response.body', body => '', more => 0 },
    ], 'matching If-None-Match wins before range delivery and is bodyless');
};

subtest 'selected-file conditions use all fields and eligible HTTP representations' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($root, 'conditional.txt');
    write_file($path, 'abcdef');
    my $response = response('File', $path, etag => '"a,b"',
        headers => ['Cache-Control' => 'private', 'Vary' => 'Accept']);
    my $matching = [
        ['If-None-Match', '"old"'], ['If-None-Match', 'W/"a,b"'],
        ['Range', 'bytes=0-1'],
    ];
    my $events = run_response($response, http_scope(headers => $matching));
    is($events->[0]{status}, 304, 'weak match in second field precedes range');
    is($events->[1], {type => 'http.response.body', body => '', more => 0},
        'matching condition is bodyless');
    is(event_header($events->[0], 'ETag'), '"a,b"', '304 retains validator');
    is(event_header($events->[0], 'Cache-Control'), 'private',
        '304 retains configured cache policy');
    is(event_header($events->[0], 'Vary'), 'Accept', '304 retains configured Vary');

    my $wildcard = run_response(response('File', $path, etag => 0),
        http_scope(headers => [['If-None-Match', '*']]));
    is($wildcard->[0]{status}, 304, 'existing selected file matches wildcard without ETag');
    ok(!defined event_header($wildcard->[0], 'ETag'),
        'wildcard does not invent a disabled validator');
    is(run_response($response, http_scope(method => 'HEAD',
        headers => $matching))->[0]{status}, 304, 'HEAD matches before range delivery');
    is(run_response($response, http_scope(method => 'POST',
        headers => $matching))->[0]{status}, 200, 'POST does not select 304');
    is(run_response($response, http_scope(method => 'get',
        headers => $matching))->[0]{status}, 200, 'method spelling must be exact');
    is(run_response(response('File', $path, status => 404, etag => '"a,b"'),
        http_scope(headers => [['If-None-Match', '*']]))->[0]{status}, 404,
        'file-backed error is not a cached representation');
    is(run_response(response('File', $path, status => 201, etag => '"a,b"'),
        http_scope(headers => [['If-None-Match', '*']]))->[0]{status}, 304,
        'successful selected representation remains conditionally eligible');
    is(run_response(response('File', $path, status => 302, etag => '"a,b"'),
        http_scope(headers => [['If-None-Match', '*']]))->[0]{status}, 302,
        'redirect does not select 304');

    for my $condition (['"a,b", nope'], [''], ['"old"']) {
        my $unmatched = run_response($response, http_scope(headers => [
            ['If-None-Match', $condition->[0]], ['Range', 'bytes=0-1'],
        ]));
        is($unmatched->[0]{status}, 206,
            'unusable or nonmatching condition preserves range delivery');
    }
    is(run_response(response('File', $path, etag => '"a,b"', handle_ranges => 0),
        http_scope(headers => [['If-None-Match', '*']]))->[0]{status}, 304,
        'disabled range processing does not disable conditionals');

    my $window = response('File', $path, offset => 1, length => 3);
    my $full_window = run_response($window);
    my $window_tag = event_header($full_window->[0], 'ETag');
    my $cached_window = run_response($window, http_scope(headers => [
        ['If-None-Match', $window_tag],
    ]));
    is($cached_window->[0]{status}, 304, 'window condition matches its representation');
    is(event_header($cached_window->[0], 'ETag'), $window_tag,
        'window ETag identity survives 304');
};

subtest 'strict single ranges operate against full files and logical windows' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($root, 'digits.txt');
    write_file($path, '0123456789');

    my $window = response('File', $path, offset => 2, length => 6);
    for my $case (
        ['bytes=1-3', 'bytes 1-3/6', 3, 3],
        ['bytes=3-',  'bytes 3-5/6', 5, 3],
        ['bytes=-2',  'bytes 4-5/6', 6, 2],
        ['bytes=-99', 'bytes 0-5/6', 2, 6],
        ['bytes=3-99','bytes 3-5/6', 5, 3],
    ) {
        my ($range, $content_range, $physical_offset, $length) = @$case;
        my $events = run_response(
            $window, http_scope(headers => [['range', $range]]),
        );
        is($events->[0]{status}, 206, "$range is satisfiable");
        is(event_header($events->[0], 'content-range'), $content_range,
            "$range reports normalized logical coordinates");
        is($events->[1]{offset}, $physical_offset,
            "$range adds the configured physical offset");
        is($events->[1]{length}, $length,
            "$range delegates the selected physical length");
    }

    my $full_range = run_response(
        response('File', $path),
        http_scope(headers => [['range', 'bytes=2-5']]),
    );
    is(event_header($full_range->[0], 'content-range'), 'bytes 2-5/10',
        'full-file ranges use complete-file logical coordinates');
    is($full_range->[1]{offset}, 2,
        'full-file client range becomes its physical offset');

    my $non_success = run_response(
        response('File', $path, status => 404),
        http_scope(headers => [['range', 'bytes=2-5']]),
    );
    is($non_success->[0]{status}, 404,
        'Range cannot replace an explicit non-200 response status');
    ok(!defined event_header($non_success->[0], 'content-range'),
        'a non-200 baseline does not advertise partial content');
    is(event_header($non_success->[0], 'content-length'), 10,
        'a non-200 baseline retains the full representation length');
    is($non_success->[1], {
        type => 'http.response.body', file => $path,
    }, 'a non-200 baseline retains full file delivery');

    for my $case (
        ['zero suffix', [['range', 'bytes=-0']]],
        ['empty range', [['range', '']]],
        ['reversed range', [['range', 'bytes=5-3']]],
        ['out of bounds', [['range', 'bytes=6-']]],
        ['multiple ranges', [['range', 'bytes=0-1,4-5']]],
        ['repeated fields', [
            ['range', 'bytes=0-1'], ['range', 'bytes=4-5'],
        ]],
    ) {
        my ($label, $headers) = @$case;
        my $events = run_response($window, http_scope(headers => $headers));
        is($events->[0]{status}, 416, "$label receives strict 416");
        is(event_header($events->[0], 'content-range'), 'bytes */6',
            "$label reports the logical window length");
        is($events->[1], {
            type => 'http.response.body', body => '', more => 0,
        }, "$label emits one empty terminal body event");
    }

    my $ignored = run_response(
        response('File', $path, offset => 2, length => 6, handle_ranges => 0),
        http_scope(headers => [['range', 'bytes=1-2']]),
    );
    is($ignored->[0]{status}, 200,
        'disabled range handling ignores a syntactically valid Range');
    ok(!defined event_header($ignored->[0], 'content-range'),
        'disabled range handling emits no Content-Range');
    is($ignored->[1]{offset}, 2,
        'disabled range handling keeps the configured physical window');
    is($ignored->[1]{length}, 6,
        'disabled range handling sends the complete logical window');
};

subtest 'trusted path ownership, retained configuration, and send settlement stay explicit' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $selected = File::Spec->catfile($root, 'selected.txt');
    my $second = File::Spec->catfile($root, 'second.txt');
    my $third = File::Spec->catfile($root, 'third.txt');
    my $url_named = File::Spec->catfile($root, 'request-path-is-not-a-file');
    write_file($selected, 'selected');
    write_file($second, 'second');
    write_file($third, 'third');
    write_file($url_named, 'must not be selected');

    my $response = T::ConfigurableFile->new(
        $selected, headers => ['X-Version' => 'first'],
    );
    my $app = $response->to_app;
    $response->select_path($second)
        ->remove_header('X-Version')
        ->header('X-Version' => 'second');

    my $app_start = Future->new;
    my @app_events;
    my $app_calls = 0;
    my $app_running = $app->(
        http_scope(path => '/request-path-is-not-a-file'), receive(),
        sub {
            push @app_events, $_[0];
            return ++$app_calls == 1 ? $app_start : Future->done;
        },
    );
    $response->select_path($third)
        ->remove_header('X-Version')
        ->header('X-Version' => 'third');
    $app_start->done;
    $app_running->get;

    is($app_events[1]{file}, $second,
        'File never maps the untrusted request URL path to disk');
    is(event_header($app_events[0], 'x-version'), 'second',
        'mutation while start is parked does not split the request-local File plan');

    my @later_events;
    $app->(
        http_scope(), receive(),
        sub { push @later_events, $_[0]; Future->done },
    )->get;
    is($later_events[1]{file}, $third,
        'a later invocation observes the later selected path');
    is(event_header($later_events[0], 'x-version'), 'third',
        'a later invocation observes later Response metadata');

    my $start_gate = Future->new;
    my $body_gate = Future->new;
    my @events;
    my $running = response('File', $selected)->to_app->(
        http_scope(), receive(),
        sub {
            push @events, $_[0];
            return @events == 1 ? $start_gate : $body_gate;
        },
    );
    is(scalar @events, 1,
        'body delivery waits for response-start settlement');
    ok(!$running->is_ready, 'response stays pending on response start');
    $start_gate->done;
    is(scalar @events, 2, 'one file body event follows settled start');
    ok(!$running->is_ready, 'response stays pending on server file delivery');
    $body_gate->fail("selected file send failed\n");
    like(dies { $running->get }, qr/selected file send failed/,
        'direct file-event send failure propagates');
    ok(!$body_gate->is_cancelled, 'File never cancels the PAGI send Future');

    my @failed_start_events;
    like(dies {
        response('File', $selected)->to_app->(
            http_scope(), receive(),
            sub {
                push @failed_start_events, $_[0];
                return Future->fail("start failed\n");
            },
        )->get;
    }, qr/start failed/, 'response-start send failure propagates');
    is(scalar @failed_start_events, 1,
        'a failed start prevents the file event');

    for my $phase (qw(start body)) {
        subtest "cancellation during pending $phase send" => sub {
            my $pending = Future->new;
            my $send_cancellations = 0;
            $pending->on_cancel(sub { ++$send_cancellations });
            my @cancel_events;

            my $cancelled_response = response('File', $selected)->to_app->(
                http_scope(), receive(),
                sub {
                    push @cancel_events, $_[0];
                    if ($phase eq 'start') {
                        return $pending if @cancel_events == 1;
                        return Future->done;
                    }
                    return Future->done if @cancel_events == 1;
                    return $pending;
                },
            );

            is(scalar @cancel_events, $phase eq 'start' ? 1 : 2,
                "response reaches the pending $phase send");
            $cancelled_response->cancel;
            ok($cancelled_response->is_cancelled,
                'caller cancellation settles the response Future');
            is($send_cancellations, 0,
                "response cancellation does not cancel the pending $phase send");
            ok(!$pending->is_ready,
                "the server retains ownership of the pending $phase send");

            $pending->done;
            is($send_cancellations, 0,
                "settling the $phase send does not manufacture cancellation");
            is(scalar @cancel_events, $phase eq 'start' ? 1 : 2,
                'cancellation does not emit another event');
        };
    }
};

subtest 'HEAD suppression remains an enclosing wire-boundary responsibility' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($root, 'head.txt');
    write_file($path, 'head representation');

    my @wire_events;
    my $terminal = Future->new;
    my ($scope, $send) = PAGI::Routing::HeadBoundary->prepare(
        http_scope(
            method => 'HEAD', headers => [['range', 'bytes=0-3']],
        ),
        sub {
            push @wire_events, $_[0];
            return @wire_events == 2 ? $terminal : Future->done;
        },
    );
    my $running = response('File', $path)->to_app->(
        $scope, receive(), $send,
    );
    is($wire_events[0]{status}, 200,
        'HEAD retains GET-equivalent selected-file status');
    is(event_header($wire_events[0], 'content-length'), 19,
        'HEAD retains GET-equivalent selected-file length');
    ok(!defined event_header($wire_events[0], 'content-range'),
        'HEAD ignores Range and retains full-representation metadata');
    is($wire_events[1], {
        type => 'http.response.body', body => '', more => 0,
    }, 'outer HeadBoundary suppresses the file event');
    ok(!$running->is_ready,
        'File still awaits the boundary terminal send Future');
    $terminal->done;
    $running->get;
};

subtest 'Plan exposes immutable request-local status, headers, and body event' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($root, 'plan.txt');
    write_file($path, 'abcdef');
    my $plan = PAGI::Response::File::Plan->new(
        path => $path,
        scope => http_scope(headers => [['range', 'bytes=1-2']]),
        offset => 1,
        length => 4,
        handle_ranges => 1,
        etag => '"plan"',
    );
    is($plan->status, 206, 'plan exposes its calculated status');
    is(event_header({ headers => $plan->headers }, 'content-range'),
        'bytes 1-2/4', 'plan exposes logical range headers');
    is($plan->body_event, {
        type => 'http.response.body', file => $path,
        offset => 2, length => 2,
    }, 'plan exposes physical delivery coordinates');

    my $headers = $plan->headers;
    $headers->[0][1] = 'mutated';
    isnt($plan->headers->[0][1], 'mutated',
        'header accessor returns an isolated value');
    my $body_event = $plan->body_event;
    $body_event->{file} = '/other';
    is($plan->body_event->{file}, $path,
        'body-event accessor returns an isolated value');
    like(dies { $plan->status(200) }, qr/read-only/i,
        'status accessor cannot mutate an existing plan');
    like(dies { $plan->headers([]) }, qr/read-only/i,
        'headers accessor cannot mutate an existing plan');
    like(dies { $plan->body_event({}) }, qr/read-only/i,
        'body-event accessor cannot mutate an existing plan');
};

done_testing;
