use strict;
use warnings;
use utf8;

use Encode qw(encode decode FB_CROAK);
use Future;
use JSON::MaybeXS qw(decode_json);
use Test2::V0;

use PAGI::Response qw(response);
use PAGI::Response::Text;
use PAGI::Response::HTML;
use PAGI::Response::JSON;
use PAGI::Response::Problem;
use PAGI::Response::Redirect;
use PAGI::Response::Empty;

sub emitted_events {
    my ($response) = @_;
    my @events;
    $response->to_app->(
        { type => 'http' },
        sub { Future->done },
        sub { push @events, $_[0]; Future->done },
    )->get;
    return \@events;
}

sub header_values {
    my ($headers, $name) = @_;
    return [ map { $_->[1] } grep { lc($_->[0]) eq lc($name) } @$headers ];
}

my @VALID_URI_REFERENCES = (
    '/relative/path',
    '../parent',
    './child',
    'a/b',
    'https://example.test/path?x=a%20b#part',
    'https://[2001:db8::1]/path',
    '//[::1]:8443/path',
    '//[v1.fe80]/',
    '//example.test:8443/path',
    'urn:example:animal:ferret:nose',
    '?q=value',
    '#fragment',
);
my @INVALID_URI_REFERENCES = (
    '/bad|target',
    '/bad%zz',
    '/bad space',
    "/bad\nuri",
    '/bad<target>',
    '/bad"target',
    '/bad[segment]',
    '?q=[x]',
    '//[bad]',
    '//[::1',
    '//[v1.]',
    '//example.test:not-a-port',
    '//example.test:80:90',
    '/one#two#three',
    '1relative:segment',
);

subtest 'text and HTML render Unicode as strict UTF-8 bytes' => sub {
    my $text = response('Text', "caf\x{e9}");
    isa_ok($text, ['PAGI::Response::Text']);
    is($text->content_type, 'text/plain; charset=utf-8', 'Text default content type');
    is($text->body, "caf\xC3\xA9", 'Text body has exact UTF-8 bytes');
    ok(!utf8::is_utf8($text->body), 'Text body is a byte scalar');
    is(length($text->body), 5, 'Text byte length is UTF-8 byte length');

    my $html = PAGI::Response::HTML->new("<b>\x{2713}</b>");
    isa_ok($html, ['PAGI::Response::HTML']);
    is($html->content_type, 'text/html; charset=utf-8', 'HTML default content type');
    is($html->body, "<b>\xE2\x9C\x93</b>", 'HTML body has exact UTF-8 bytes');
    is(length($html->body), 10, 'HTML byte length is UTF-8 byte length');

    like(dies { response('Text', 'hello', charset => 'iso-8859-1') },
        qr/unknown response option 'charset'/i, 'Text rejects a variable charset option');
    like(dies { response('HTML', 'hello', charset => 'iso-8859-1') },
        qr/unknown response option 'charset'/i, 'HTML rejects a variable charset option');
    like(dies { response('Text', undef) }, qr/Unicode scalar/i,
        'Text rejects an undefined character value');
    like(dies { response('HTML', []) }, qr/Unicode scalar/i,
        'HTML rejects a reference character value');
    my $surrogate = chr(0xD800);
    like(dies { response('Text', $surrogate) }, qr/(?:UTF-8|surrogate|wide)/i,
        'Text rejects a lone UTF-8 surrogate');
    like(dies { response('HTML', $surrogate) }, qr/(?:UTF-8|surrogate|wide)/i,
        'HTML rejects a lone UTF-8 surrogate');
    like(dies { response('Text', 'x', status => 200, status => 201) }, qr/duplicate/i,
        'Text rejects duplicate option names');
    like(dies { response('HTML', 'x', 'status') }, qr/name.value pairs/i,
        'HTML rejects malformed option lists');
};

subtest 'base Response remains the explicit non-UTF-8 byte escape hatch' => sub {
    my $characters = "caf\x{e9}";
    my $latin1 = encode('iso-8859-1', $characters, FB_CROAK);
    my $base = PAGI::Response->new($latin1, content_type => 'text/plain; charset=iso-8859-1');
    is($base->body, "caf\xE9", 'base Response preserves caller-encoded bytes');
    is($base->content_type, 'text/plain; charset=iso-8859-1',
        'base Response preserves caller-selected charset');
    for my $status (100, 204, 205, 304) {
        like(dies { PAGI::Response->new('', status => $status) }, qr/body.*\Q$status\E/i,
            "base Response rejects an empty body for status $status");
        like(dies { response('Text', '', status => $status) }, qr/body.*\Q$status\E/i,
            "Text rejects an empty body for status $status");
    }
};

subtest 'JSON produces UTF-8 bytes with semantic round trips' => sub {
    my $json = response('JSON', { ok => \1, name => "caf\x{e9}", values => [1, 2] });
    isa_ok($json, ['PAGI::Response::JSON']);
    is($json->content_type, 'application/json', 'JSON default content type');
    ok(!utf8::is_utf8($json->body), 'JSON body is a byte scalar');
    is(decode_json($json->body), { ok => \1, name => "caf\x{e9}", values => [1, 2] },
        'JSON body round trips without a key-order promise');
    like(dies { response('JSON', bless({}, 'T::Unencodable')) }, qr/(?:encod|JSON)/i,
        'JSON reports encoding failures');
};

subtest 'Problem validates RFC 9457 members without materializing omissions' => sub {
    my $minimal = response('Problem', {});
    isa_ok($minimal, ['PAGI::Response::Problem']);
    is($minimal->content_type, 'application/problem+json', 'Problem default content type');
    is($minimal->status, 200, 'absent document status leaves the HTTP default');
    is(decode_json($minimal->body), {},
        'absent type remains absent on wire while its effective value is about:blank');

    my $full = response('Problem', {
        type       => '/problems/invalid',
        title      => 'Invalid request',
        status     => 422,
        detail     => "name must be caf\x{e9}",
        instance   => '../requests/42',
        retry_after => 30,
        metadata   => { field => 'name' },
    });
    is($full->status, 422, 'document status supplies HTTP status');
    is(decode_json($full->body), {
        type       => '/problems/invalid',
        title      => 'Invalid request',
        status     => 422,
        detail     => "name must be caf\x{e9}",
        instance   => '../requests/42',
        retry_after => 30,
        metadata   => { field => 'name' },
    }, 'optional members and extensions are retained verbatim');

    is(response('Problem', { title => 'Nope' }, status => 400)->status, 400,
        'constructor status does not inject a missing document status');
    is(decode_json(response('Problem', { title => 'Nope' }, status => 400)->body),
        { title => 'Nope' }, 'constructor status remains absent from the document');

    like(dies { response('Problem', []) }, qr/hashref/i, 'Problem requires a hashref');
    like(dies { response('Problem', { type => [] }) }, qr/type.*URI-reference/i,
        'Problem validates type URI references');
    for my $uri (@VALID_URI_REFERENCES) {
        is(decode_json(response('Problem', { type => $uri })->body)->{type}, $uri,
            "Problem retains valid URI-reference $uri");
    }
    for my $uri (@INVALID_URI_REFERENCES) {
        like(dies { response('Problem', { type => $uri }) }, qr/type.*URI-reference/i,
            "Problem rejects malformed URI-reference $uri");
    }
    like(dies { response('Problem', { instance => [] }) }, qr/instance.*URI-reference/i,
        'Problem validates instance URI references');
    like(dies { response('Problem', { title => [] }) }, qr/title.*string/i,
        'Problem validates title strings');
    like(dies { response('Problem', { detail => undef }) }, qr/detail.*string/i,
        'Problem validates detail strings');
    like(dies { response('Problem', { status => 99 }) }, qr/status.*100.*599/i,
        'Problem validates document status bounds');
    like(dies { response('Problem', { status => '400.5' }) }, qr/status.*integer/i,
        'Problem validates document status integers');
    like(dies { response('Problem', { status => 400 }, status => 401) }, qr/must agree/i,
        'Problem requires document and HTTP statuses to agree');
    like(dies { response('Problem', { extra => bless({}, 'T::Unencodable') }) }, qr/(?:encod|JSON)/i,
        'Problem validates extension JSON encodability');
    like(dies { response('Problem', {}, status => 400, status => 401) }, qr/duplicate/i,
        'Problem rejects duplicate constructor option names');
};

subtest 'Problem validates its document status before each retained-object invocation' => sub {
    my $locked = response('Problem', { title => 'Locked', status => 422 });
    like(dies { $locked->status(409) }, qr/Problem document and HTTP statuses must agree/,
        'incompatible public status mutation is rejected');
    is($locked->status, 422, 'rejected mutation leaves the agreed status intact');
    is($locked->status(422), $locked, 'matching status assignment remains chainable');

    my $bypassed = response('Problem', { title => 'Bypassed', status => 422 });
    PAGI::Response::status($bypassed, 409);
    my @events;
    like(dies {
        $bypassed->to_app->(
            { type => 'http' },
            sub { Future->done },
            sub { push @events, $_[0]; Future->done },
        )->get;
    }, qr/Problem document and HTTP statuses must agree/,
        'invocation validation catches a fully qualified base mutation');
    is(\@events, [], 'an invalid Problem emits no event');
    my $bypassed_app;
    is(dies { $bypassed_app = $bypassed->to_app }, undef,
        'to_app retains an inconsistent Problem without starting a response');
    my @bypassed_app_events;
    like(dies {
        $bypassed_app->(
            { type => 'http' },
            sub { Future->done },
            sub { push @bypassed_app_events, $_[0]; Future->done },
        )->get;
    }, qr/Problem document and HTTP statuses must agree/,
        'a retained inconsistent Problem is rejected at invocation');
    is(\@bypassed_app_events, [], 'retained invalid Problem emits no event');

    my $stable = response('Problem', { title => 'Stable', status => 422 });
    my $app = $stable->to_app;
    PAGI::Response::status($stable, 409);
    my @later_events;
    like(dies {
        $app->(
            { type => 'http' },
            sub { Future->done },
            sub { push @later_events, $_[0]; Future->done },
        )->get;
    }, qr/Problem document and HTTP statuses must agree/,
        'mutation after to_app affects the later invocation');
    is(\@later_events, [], 'later invalid Problem mutation fails before start');
};

subtest 'Redirect validates status and URI references then builds safe finite HTML' => sub {
    my $target = '/next?x=%3Cscript%3E&q=%22quoted%22';
    my $redirect = response('Redirect', $target);
    isa_ok($redirect, ['PAGI::Response::Redirect']);
    is($redirect->status, 302, 'Redirect defaults to 302');
    is($redirect->header('Location'), $target,
        'Redirect installs the exact validated Location');
    is($redirect->content_type, 'text/html; charset=utf-8', 'Redirect has HTML content');
    my $body = decode('UTF-8', $redirect->body, FB_CROAK);
    like($body, qr{href="/next\?x=%3Cscript%3E&amp;q=%22quoted%22"},
        'Redirect escapes the Location in HTML attributes');
    unlike($body, qr{<script>}, 'Redirect body never embeds target markup');

    for my $status (301, 302, 303, 307, 308) {
        is(response('Redirect', '../there', status => $status)->status, $status,
            "Redirect accepts status $status");
    }
    is(response('Redirect', 'https://example.test/there')->header('Location'),
        'https://example.test/there', 'Redirect accepts absolute URI references');
    for my $uri (@VALID_URI_REFERENCES) {
        is(response('Redirect', $uri)->header('Location'), $uri,
            "Redirect accepts valid URI-reference $uri");
    }
    for my $uri (@INVALID_URI_REFERENCES) {
        like(dies { response('Redirect', $uri) }, qr/URI-reference/i,
            "Redirect rejects malformed URI-reference $uri");
    }
    like(dies { response('Redirect', '/next', status => 200) }, qr/301.*302.*303.*307.*308/i,
        'Redirect rejects non-redirect statuses');
    like(dies { response('Redirect', '/next', headers => [Location => '/other']) }, qr/Location.*owned/i,
        'Redirect rejects a caller Location conflict');
    like(dies { response('Redirect', '/next', status => 301, status => 302) }, qr/duplicate/i,
        'Redirect rejects duplicate constructor option names');

    my $flagged = '/ascii-only';
    utf8::upgrade($flagged);
    my $normalized = response('Redirect', $flagged);
    is($normalized->header('Location'), '/ascii-only',
        'Redirect normalizes an ASCII-valid flagged Location');
    ok(!utf8::is_utf8($normalized->body),
        'Redirect renders an ASCII-valid flagged Location to byte body');
};

subtest 'Redirect preserves response-owned status, Location, and body invariants' => sub {
    my $locked = response('Redirect', '/canonical');
    like(dies { $locked->status(301) }, qr/Redirect status is response-owned/,
        'status mutation that would stale the body is rejected');
    is($locked->status, 302, 'rejected status mutation leaves the canonical status');
    is($locked->status(302), $locked, 'matching status assignment remains chainable');
    like(dies { $locked->remove_header('Location') }, qr/Redirect Location is response-owned/,
        'response-level Location removal is rejected immediately');
    like(dies { $locked->header('Location', '/other') }, qr/Redirect Location is response-owned/,
        'response-level Location addition is rejected immediately');

    my @container_mutations = (
        set    => sub { $_[0]->headers->set('Location', '/other') },
        add    => sub { $_[0]->headers->add('Location', '/other') },
        remove => sub { $_[0]->headers->remove('Location') },
        clear  => sub { $_[0]->headers->clear },
    );
    while (@container_mutations) {
        my ($name, $mutate) = splice @container_mutations, 0, 2;

        my $for_emission = response('Redirect', '/canonical');
        $mutate->($for_emission);
        my @events;
        like(dies {
            $for_emission->to_app->(
                { type => 'http' },
                sub { Future->done },
                sub { push @events, $_[0]; Future->done },
            )->get;
        }, qr/Redirect requires exactly one canonical Location/,
            "headers->$name mutation is rejected before emission");
        is(\@events, [], "headers->$name mutation emits no event");

        my $for_app = response('Redirect', '/canonical');
        my $app = $for_app->to_app;
        $mutate->($for_app);
        my @app_events;
        like(dies {
            $app->(
                { type => 'http' },
                sub { Future->done },
                sub { push @app_events, $_[0]; Future->done },
            )->get;
        }, qr/Redirect requires exactly one canonical Location/,
            "headers->$name mutation after to_app is rejected at invocation");
        is(\@app_events, [], "headers->$name retained-object failure emits no event");
    }

    my $status_bypass = response('Redirect', '/canonical');
    PAGI::Response::status($status_bypass, 301);
    my @status_events;
    like(dies {
        $status_bypass->to_app->(
            { type => 'http' },
            sub { Future->done },
            sub { push @status_events, $_[0]; Future->done },
        )->get;
    }, qr/Redirect status is response-owned/,
        'invocation validation catches a fully qualified base status mutation');
    is(\@status_events, [], 'a stale redirect body emits no event');

    my $stable = response('Redirect', '/canonical');
    my $app = $stable->to_app;
    $stable->headers->set('Location', '/mutated');
    PAGI::Response::status($stable, 301);
    my @later_events;
    like(dies {
        $app->(
            { type => 'http' },
            sub { Future->done },
            sub { push @later_events, $_[0]; Future->done },
        )->get;
    }, qr/Redirect status is response-owned/,
        'invalid status mutation after to_app affects the later invocation');
    is(\@later_events, [], 'later invalid Redirect mutation fails before start');
};

subtest 'Empty owns zero bytes without a default content type' => sub {
    my $empty = response('Empty');
    isa_ok($empty, ['PAGI::Response::Empty']);
    is($empty->status, 204, 'Empty defaults to 204');
    is($empty->body, '', 'Empty owns zero body bytes');
    ok(!$empty->has_content_type, 'Empty has no default Content-Type');
    for my $status (100, 204, 205, 304) {
        is(response('Empty', status => $status)->body, '',
            "Empty supports status $status with zero bytes");
    }
    like(dies { response('Empty', body => 'not empty') }, qr/unknown response option 'body'/i,
        'Empty rejects supplied body content');
    like(dies { response('Empty', content_type => 'text/plain') }, qr/Content-Type/i,
        'Empty rejects content_type constructor option');
    like(dies { response('Empty', headers => ['Content-Type' => 'text/plain']) }, qr/Content-Type/i,
        'Empty rejects Content-Type supplied through headers');
    like(dies { response('Empty', status => 204, status => 205) }, qr/duplicate/i,
        'Empty rejects duplicate constructor option names');

    my $framed = emitted_events(response('Empty',
        status => 204,
        headers => ['X-Empty' => 'yes', 'Transfer-Encoding' => 'chunked'],
    ));
    is(header_values($framed->[0]{headers}, 'content-length'), [],
        '204 Empty emits no Content-Length');
    is(header_values($framed->[0]{headers}, 'transfer-encoding'), [],
        '204 Empty emits no Transfer-Encoding');
    is(header_values($framed->[0]{headers}, 'x-empty'), ['yes'],
        'Empty preserves ordinary headers on emission');
    for my $status (100, 304) {
        my $events = emitted_events(response('Empty', status => $status));
        is(header_values($events->[0]{headers}, 'content-length'), [],
            "$status Empty emits no Content-Length");
        is(header_values($events->[0]{headers}, 'transfer-encoding'), [],
            "$status Empty emits no Transfer-Encoding");
    }
    my $reset = emitted_events(response('Empty', status => 205));
    is(header_values($reset->[0]{headers}, 'content-length'), [0],
        '205 Empty emits the required zero Content-Length');
    is(header_values($reset->[0]{headers}, 'transfer-encoding'), [],
        '205 Empty emits no Transfer-Encoding');

    for my $method (qw(set add)) {
        my $mutated = response('Empty');
        $mutated->headers->$method('Content-Type', 'text/plain');
        my @events;
        like(dies {
            $mutated->to_app->(
                { type => 'http' },
                sub { Future->done },
                sub { push @events, $_[0]; Future->done },
            )->get;
        }, qr/Content-Type/i, "Empty rejects headers->$method Content-Type at emission");
        is(\@events, [], "headers->$method Content-Type emits zero events");
    }
};

done_testing;
