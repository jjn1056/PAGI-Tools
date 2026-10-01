use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use PAGI::Compose qw(compose);
use PAGI::Request;
use PAGI::Response qw(json_response);
use PAGI::Routing qw(middleware route);
use PAGI::Test::Client;

# A body the client got wrong is the client's error. The buffered body
# helpers throw PAGI::Request::BodyError -- status_code 400, or 413 for a
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

subtest 'each client mistake is a BodyError with a status, a reason and a safe message' => sub {
    my @cases = (
        [ 'invalid JSON', 400, 'invalid_json',
          sub { request_with('{not json')->json } ],
        [ 'invalid UTF-8 text (strict)', 400, 'invalid_encoding',
          sub { request_with("caf\xE9")->text(strict => 1) } ],
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
        isa_ok($error, 'PAGI::Request::BodyError');
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

subtest 'a Compose application answers 400 or 413, and logs nothing' => sub {
    my $app = compose(routes => [
        route('/json' => async sub { my ($r) = @_; json_response(await $r->json) }, methods => ['POST']),
        route('/form' => async sub { my ($r) = @_; await $r->form_params(max_field_size => 10); json_response({}) },
            methods => ['POST']),
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
    }
    is([$res{json}->status, $res{json}->header('content-type')], [400, 'application/problem+json'],
        'invalid JSON is a negotiated 400');
    is($res{form}->status, 413, 'an oversized part is a 413');
    is($stderr, '', 'and neither is reported as a server error');
};

subtest 'an application can render body errors its own way' => sub {
    my $app = compose(
        middleware => [middleware('ErrorHandler', handler => sub {
            my ($request, $error) = @_;
            return json_response({ error => $error->message }, status => $error->status_code)
                if ref $error && $error->isa('PAGI::Request::BodyError');
            return json_response({ error => 'Something went wrong.' }, status => 500);
        })],
        routes => [route('/json' => async sub { my ($r) = @_; json_response(await $r->json) },
            methods => ['POST'])],
    );
    my $res = PAGI::Test::Client->new(app => $app)->post('/json', body => '{not json',
        headers => { 'Content-Type' => 'application/json' });
    is([$res->status, $res->json], [400, { error => 'The request body is not valid JSON.' }],
        'an ErrorHandler handler sees the BodyError and chooses the response');
};

done_testing;
