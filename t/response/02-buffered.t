use strict;
use warnings;
use utf8;

use Encode qw(encode decode FB_CROAK);
use Future;
use JSON::MaybeXS qw(decode_json);
use Test2::V0;

use PAGI::Response qw(
    response text_response html_response json_response problem_response
    redirect_response empty_response
);
use PAGI::Response::Text;
use PAGI::Response::HTML;
use PAGI::Response::JSON;
use PAGI::Response::Problem;
use PAGI::Response::Redirect;
use PAGI::Response::Empty;

sub emitted_events {
    my ($response) = @_;
    my @events;
    $response->respond(
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
    '//example.test:not-a-port',
    '//example.test:80:90',
    '/one#two#three',
    '1relative:segment',
);

subtest 'text and HTML render Unicode as strict UTF-8 bytes' => sub {
    my $text = text_response("caf\x{e9}");
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

    like(dies { text_response('hello', charset => 'iso-8859-1') },
        qr/unknown response option 'charset'/i, 'Text rejects a variable charset option');
    like(dies { html_response('hello', charset => 'iso-8859-1') },
        qr/unknown response option 'charset'/i, 'HTML rejects a variable charset option');
    like(dies { text_response(undef) }, qr/Unicode scalar/i,
        'Text rejects an undefined character value');
    like(dies { html_response([]) }, qr/Unicode scalar/i,
        'HTML rejects a reference character value');
    my $surrogate = chr(0xD800);
    like(dies { text_response($surrogate) }, qr/(?:UTF-8|surrogate|wide)/i,
        'Text rejects a lone UTF-8 surrogate');
    like(dies { html_response($surrogate) }, qr/(?:UTF-8|surrogate|wide)/i,
        'HTML rejects a lone UTF-8 surrogate');
    like(dies { text_response('x', status => 200, status => 201) }, qr/duplicate/i,
        'Text rejects duplicate option names');
    like(dies { html_response('x', 'status') }, qr/name.value pairs/i,
        'HTML rejects malformed option lists');
};

subtest 'base Response remains the explicit non-UTF-8 byte escape hatch' => sub {
    my $characters = "caf\x{e9}";
    my $latin1 = encode('iso-8859-1', $characters, FB_CROAK);
    my $base = response($latin1, content_type => 'text/plain; charset=iso-8859-1');
    is($base->body, "caf\xE9", 'base Response preserves caller-encoded bytes');
    is($base->content_type, 'text/plain; charset=iso-8859-1',
        'base Response preserves caller-selected charset');
    for my $status (100, 204, 205, 304) {
        like(dies { response('', status => $status) }, qr/body.*\Q$status\E/i,
            "base Response rejects an empty body for status $status");
        like(dies { text_response('', status => $status) }, qr/body.*\Q$status\E/i,
            "Text rejects an empty body for status $status");
    }
};

subtest 'JSON produces UTF-8 bytes with semantic round trips' => sub {
    my $json = json_response({ ok => \1, name => "caf\x{e9}", values => [1, 2] });
    isa_ok($json, ['PAGI::Response::JSON']);
    is($json->content_type, 'application/json', 'JSON default content type');
    ok(!utf8::is_utf8($json->body), 'JSON body is a byte scalar');
    is(decode_json($json->body), { ok => \1, name => "caf\x{e9}", values => [1, 2] },
        'JSON body round trips without a key-order promise');
    like(dies { json_response(bless({}, 'T::Unencodable')) }, qr/(?:encod|JSON)/i,
        'JSON reports encoding failures');
};

subtest 'Problem validates RFC 9457 members without materializing omissions' => sub {
    my $minimal = problem_response({});
    isa_ok($minimal, ['PAGI::Response::Problem']);
    is($minimal->content_type, 'application/problem+json', 'Problem default content type');
    is($minimal->status, 200, 'absent document status leaves the HTTP default');
    is(decode_json($minimal->body), {},
        'absent type remains absent on wire while its effective value is about:blank');

    my $full = problem_response({
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

    is(problem_response({ title => 'Nope' }, status => 400)->status, 400,
        'constructor status does not inject a missing document status');
    is(decode_json(problem_response({ title => 'Nope' }, status => 400)->body),
        { title => 'Nope' }, 'constructor status remains absent from the document');

    like(dies { problem_response([]) }, qr/hashref/i, 'Problem requires a hashref');
    like(dies { problem_response({ type => [] }) }, qr/type.*URI-reference/i,
        'Problem validates type URI references');
    for my $uri (@VALID_URI_REFERENCES) {
        is(decode_json(problem_response({ type => $uri })->body)->{type}, $uri,
            "Problem retains valid URI-reference $uri");
    }
    for my $uri (@INVALID_URI_REFERENCES) {
        like(dies { problem_response({ type => $uri }) }, qr/type.*URI-reference/i,
            "Problem rejects malformed URI-reference $uri");
    }
    like(dies { problem_response({ instance => [] }) }, qr/instance.*URI-reference/i,
        'Problem validates instance URI references');
    like(dies { problem_response({ title => [] }) }, qr/title.*string/i,
        'Problem validates title strings');
    like(dies { problem_response({ detail => undef }) }, qr/detail.*string/i,
        'Problem validates detail strings');
    like(dies { problem_response({ status => 99 }) }, qr/status.*100.*599/i,
        'Problem validates document status bounds');
    like(dies { problem_response({ status => '400.5' }) }, qr/status.*integer/i,
        'Problem validates document status integers');
    like(dies { problem_response({ status => 400 }, status => 401) }, qr/must agree/i,
        'Problem requires document and HTTP statuses to agree');
    like(dies { problem_response({ extra => bless({}, 'T::Unencodable') }) }, qr/(?:encod|JSON)/i,
        'Problem validates extension JSON encodability');
    like(dies { problem_response({}, status => 400, status => 401) }, qr/duplicate/i,
        'Problem rejects duplicate constructor option names');
};

subtest 'Redirect validates status and URI references then builds safe finite HTML' => sub {
    my $target = '/next?x=%3Cscript%3E&q=%22quoted%22';
    my $redirect = redirect_response($target);
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
        is(redirect_response('../there', status => $status)->status, $status,
            "Redirect accepts status $status");
    }
    is(redirect_response('https://example.test/there')->header('Location'),
        'https://example.test/there', 'Redirect accepts absolute URI references');
    for my $uri (@VALID_URI_REFERENCES) {
        is(redirect_response($uri)->header('Location'), $uri,
            "Redirect accepts valid URI-reference $uri");
    }
    for my $uri (@INVALID_URI_REFERENCES) {
        like(dies { redirect_response($uri) }, qr/URI-reference/i,
            "Redirect rejects malformed URI-reference $uri");
    }
    like(dies { redirect_response('/next', status => 200) }, qr/301.*302.*303.*307.*308/i,
        'Redirect rejects non-redirect statuses');
    like(dies { redirect_response('/next', headers => [Location => '/other']) }, qr/Location.*owned/i,
        'Redirect rejects a caller Location conflict');
    like(dies { redirect_response('/next', status => 301, status => 302) }, qr/duplicate/i,
        'Redirect rejects duplicate constructor option names');

    my $flagged = '/ascii-only';
    utf8::upgrade($flagged);
    my $normalized = redirect_response($flagged);
    is($normalized->header('Location'), '/ascii-only',
        'Redirect normalizes an ASCII-valid flagged Location');
    ok(!utf8::is_utf8($normalized->body),
        'Redirect renders an ASCII-valid flagged Location to byte body');
};

subtest 'Empty owns zero bytes without a default content type' => sub {
    my $empty = empty_response();
    isa_ok($empty, ['PAGI::Response::Empty']);
    is($empty->status, 204, 'Empty defaults to 204');
    is($empty->body, '', 'Empty owns zero body bytes');
    ok(!$empty->has_content_type, 'Empty has no default Content-Type');
    for my $status (100, 204, 205, 304) {
        is(empty_response(status => $status)->body, '',
            "Empty supports status $status with zero bytes");
    }
    like(dies { empty_response(body => 'not empty') }, qr/unknown response option 'body'/i,
        'Empty rejects supplied body content');
    like(dies { empty_response(content_type => 'text/plain') }, qr/Content-Type/i,
        'Empty rejects content_type constructor option');
    like(dies { empty_response(headers => ['Content-Type' => 'text/plain']) }, qr/Content-Type/i,
        'Empty rejects Content-Type supplied through headers');
    like(dies { empty_response(status => 204, status => 205) }, qr/duplicate/i,
        'Empty rejects duplicate constructor option names');

    my $framed = emitted_events(empty_response(
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
        my $events = emitted_events(empty_response(status => $status));
        is(header_values($events->[0]{headers}, 'content-length'), [],
            "$status Empty emits no Content-Length");
        is(header_values($events->[0]{headers}, 'transfer-encoding'), [],
            "$status Empty emits no Transfer-Encoding");
    }
    my $reset = emitted_events(empty_response(status => 205));
    is(header_values($reset->[0]{headers}, 'content-length'), [0],
        '205 Empty emits the required zero Content-Length');
    is(header_values($reset->[0]{headers}, 'transfer-encoding'), [],
        '205 Empty emits no Transfer-Encoding');

    for my $method (qw(set add)) {
        my $mutated = empty_response();
        $mutated->headers->$method('Content-Type', 'text/plain');
        my @events;
        like(dies {
            $mutated->respond(
                { type => 'http' },
                sub { Future->done },
                sub { push @events, $_[0]; Future->done },
            )->get;
        }, qr/Content-Type/i, "Empty rejects headers->$method Content-Type at emission");
        is(\@events, [], "headers->$method Content-Type emits zero events");
    }
};

done_testing;
