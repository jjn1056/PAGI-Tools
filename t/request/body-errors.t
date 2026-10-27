use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use PAGI::Compose qw(compose);
use PAGI::Request;
use PAGI::Response qw(response);
use PAGI::Routing qw(middleware route);
use PAGI::Test::Client;

# A body the client got wrong is the client's error. The buffered body
# helpers throw PAGI::Exception::RequestBody -- status_code 400, or 413 for a
# part over a limit -- which every Compose application renders as that
# status, as a handled outcome rather than a server error.

sub request_with {
    my ($body, @headers) = @_;
    my $sent = 0;
    my $receive = sub {
        return Future->done({ type => 'http.disconnect' }) if $sent++;
        return Future->done({ type => 'http.request', body => $body, more => 0 });
    };
    return PAGI::Request->new({ type => 'http', method => 'POST', headers => [@headers] }, $receive);
}

sub error_from {
    my ($code) = @_;
    my $error = dies { (async sub { await $code->() })->()->get };
    return $error;
}

my $boundary = 'XtestBOUNDARYx';
my $multipart = ['Content-Type', "multipart/form-data; boundary=$boundary"];
sub part {
    my ($name, $content, $filename) = @_;
    my $disposition = qq{form-data; name="$name"} . (defined $filename ? qq{; filename="$filename"} : '');
    return "--$boundary\r\nContent-Disposition: $disposition\r\n\r\n$content\r\n";
}

subtest 'each client mistake is a RequestBody exception with a status, a reason and a safe message' => sub {
    my @cases = (
        [ 'invalid JSON', 400, 'invalid_json',
          sub { request_with('{not json')->json } ],
        [ 'invalid UTF-8 text (strict)', 400, 'invalid_encoding',
          sub { request_with("caf\xE9")->text(strict => 1) } ],
        [ 'invalid UTF-8 stream (strict)', 400, 'invalid_encoding',
          sub { request_with("caf\xE9")->body_stream(decode => 'UTF-8', strict => 1)->next_chunk } ],
        [ 'text in a charset Perl does not know', 415, 'unsupported_charset',
          sub { request_with("caf\xC3\xA9", ['Content-Type', 'text/plain; charset=x-bogus'])->text } ],
        [ 'invalid UTF-8 form (strict)', 400, 'invalid_encoding',
          sub { request_with("name=caf%E9", ['Content-Type', 'application/x-www-form-urlencoded'])
              ->form_params(strict => 1) } ],
        [ 'multipart without a boundary', 400, 'invalid_multipart',
          sub { request_with('x', ['Content-Type', 'multipart/form-data'])->form_params } ],
        [ 'a field over max_field_size', 413, 'too_large',
          sub { request_with(part('note', 'x' x 50) . "--$boundary--\r\n", $multipart)
              ->form_params(max_field_size => 10) } ],
        [ 'a file over max_file_size', 413, 'too_large',
          sub { request_with(part('upload', 'x' x 50, 'a.txt') . "--$boundary--\r\n", $multipart)
              ->form_params(max_file_size => 10) } ],
        [ 'too many fields', 413, 'too_large',
          sub { request_with(part('a', 1) . part('b', 2) . "--$boundary--\r\n", $multipart)
              ->form_params(max_fields => 1) } ],
    );
    for my $case (@cases) {
        my ($label, $status, $reason, $code) = @$case;
        my $error = error_from($code);
        isa_ok($error, 'PAGI::Exception::RequestBody');
        is([$error->status_code, $error->reason], [$status, $reason], "$label: $status $reason");
        ok(length $error->message, "$label: has a message for the client");
        is("$error", $error->message, "$label: stringifies to its message");
    }

    my $json = error_from(sub { request_with('{not json')->json });
    like($json->cause, qr/expected/, "the decoder's own error is kept as cause, for logs");
};

subtest 'the existing messages are kept, so code matching them still works' => sub {
    like(error_from(sub { request_with(part('note', 'x' x 50) . "--$boundary--\r\n", $multipart)
        ->form_params(max_field_size => 10) }), qr/Form field too large \(max 10 bytes\)/);
    like(error_from(sub { request_with('x', ['Content-Type', 'multipart/form-data'])->form_params }),
        qr/No boundary found in Content-Type/);
};

subtest 'a stream response already started cannot answer 400: it is cut short' => sub {
    # Stream sends its start before the producer reads the body.
    my $app = compose(routes => [route('/' => async sub {
        my ($r) = @_;
        my $text = $r->body_stream(decode => 'UTF-8', strict => 1);
        response('Stream', async sub {
            my ($writer) = @_;
            while (defined(my $chunk = await $text->next_chunk)) { await $writer->write($chunk) }
        });
    }, methods => ['POST'])]);
    my $res = PAGI::Test::Client->new(app => $app)->post('/', body => "caf\xFF");
    isa_ok($res->exception, 'PAGI::Exception::RequestBody');
    isnt($res->status, 400, 'no 400 can follow a started response');
};

subtest 'a Compose application answers 400 or 413, and logs nothing' => sub {
    my $app = compose(routes => [
        route('/json' => async sub { my ($r) = @_; response('JSON', await $r->json) }, methods => ['POST']),
        route('/form' => async sub { my ($r) = @_; await $r->form_params(max_field_size => 10); response('JSON', {}) },
            methods => ['POST']),
        route('/stream' => async sub {
            my ($r) = @_;
            my $body = $r->body_stream(max_bytes => 10);
            1 while defined(await $body->next_chunk);
            response('JSON', {});
        }, methods => ['POST']),
    ]);
    my $client = PAGI::Test::Client->new(app => $app);
    my ($stderr, %res) = ('');
    {
        local *STDERR;
        open STDERR, '>', \$stderr or die $!;
        $res{json} = $client->post('/json', body => '{not json',
            headers => { 'Content-Type' => 'application/json', Accept => 'application/json' });
        $res{form} = $client->post('/form', body => part('note', 'x' x 50) . "--$boundary--\r\n",
            headers => { 'Content-Type' => "multipart/form-data; boundary=$boundary", Accept => 'application/json' });
        $res{stream} = $client->post('/stream', body => 'x' x 50);
    }
    is([$res{json}->status, $res{json}->header('content-type'), $res{json}->text],
        [400, 'text/plain; charset=utf-8', 'The request body is not valid JSON.'],
        'invalid JSON is a plain 400 carrying the client message');
    is($res{form}->status, 413, 'an oversized part is a 413');
    is($res{stream}->status, 413, 'a streamed body over max_bytes is a 413');
    is($stderr, '', 'and neither is reported as a server error');
};

subtest 'an application can render body errors its own way' => sub {
    my $app = compose(
        middleware => [middleware('ErrorHandler', catch => { 'PAGI::Exception::RequestBody' => sub {
            my ($request, $error) = @_;
            return response('JSON', { error => $error->message });
        } })],
        routes => [route('/json' => async sub { my ($r) = @_; response('JSON', await $r->json) },
            methods => ['POST'])],
    );
    my $res = PAGI::Test::Client->new(app => $app)->post('/json', body => '{not json',
        headers => { 'Content-Type' => 'application/json' });
    is([$res->status, $res->json], [400, { error => 'The request body is not valid JSON.' }],
        'an ErrorHandler catch entry gets the RequestBody exception and chooses the response');
};

subtest 'a RequestBody error is an HTTP error: one PAGI::Exception::HTTP entry answers it' => sub {
    require PAGI::Exception::RequestBody;
    my $error = PAGI::Exception::RequestBody->new(reason => 'invalid_json', message => 'nope');
    isa_ok $error, ['PAGI::Exception::HTTP'];
    is $error->headers, [], 'with no headers of its own';
    is "$error", 'nope', 'and its own text';

    my $json_route = route('/notes' => async sub { my ($request) = @_; await $request->json; response('Text', 'ok') },
        methods => ['POST']);
    my %bad = (body => '{not json', headers => { 'Content-Type' => 'application/json' });
    my $app = compose(routes => [$json_route], middleware => [middleware('ErrorHandler', catch => {
        'PAGI::Exception::HTTP' => sub { my ($request, $e) = @_; response('JSON', { error => $e->message }) },
    })]);
    my $res = PAGI::Test::Client->new(app => $app)->post('/notes', %bad);
    is [$res->status, $res->json], [400, { error => 'The request body is not valid JSON.' }], 'the HTTP entry answers a bad body';

    $app = compose(routes => [$json_route], middleware => [middleware('ErrorHandler', catch => {
        'PAGI::Exception::HTTP'        => sub { response('Text', 'http') },
        'PAGI::Exception::RequestBody' => sub { response('Text', 'body') },
    })]);
    is(PAGI::Test::Client->new(app => $app)->post('/notes', %bad)->text, 'body', 'a RequestBody entry, more specific, still wins');
};

done_testing;
