use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::CSRF qw(csrf csrf_protect);
use PAGI::Middleware::CSRF;
use PAGI::Test::Client;
use PAGI::Tools qw(compose middleware response route);

# A plain HTML form carries its token in a hidden field. The middleware
# never reads the body: with form_field set, an unsafe form post without the
# header reaches the route unrefused, and csrf_protect, around the route's
# handler, reads the field from the handler's own Request.

# The handler reports the recorded failure and, for each comma-separated
# name in ?read=, what that body reader gives -- or how it dies.
my $called = 0;
my %reader = (
    form    => async sub { (await $_[0]->form_params)->get('title') // '' },
    body    => async sub { await $_[0]->body },
    json    => async sub { (await $_[0]->json)->{title} },
    uploads => async sub { scalar((await $_[0]->uploads)->values) },
    stream  => async sub { $_[0]->body_stream; 'streams' },
    mstream => async sub { $_[0]->multipart_stream; 'streams' },
);
async sub report {
    my ($request) = @_;
    $called++;
    my @parts = ('failure=' . (csrf($request)->failure // 'none'));
    for my $name (split /,/, $request->query_param('read') // '') {
        my $got = await $reader{$name}->($request)
            ->else(sub { my ($error) = @_; Future->done('dies: ' . ($error =~ s/ at \S+ line \d+.*//sr)) });
        push @parts, "$name=$got";
    }
    return response('Text', join ' | ', @parts);
}

# '/' is a plain route; '/protected' is the same handler under csrf_protect.
sub client_with {
    my (%csrf) = @_;
    my @methods = (methods => [qw(GET POST PUT PATCH DELETE)]);
    return PAGI::Test::Client->new(app => compose(
        routes     => [route('/' => \&report, @methods), route('/protected' => csrf_protect(\&report), @methods)],
        middleware => [middleware('CSRF', %csrf)],
    ));
}

# A client holding its CSRF cookie, and the token in it.
sub primed {
    my $client = client_with(@_);
    $client->get('/');
    return ($client, $client->cookie('csrf_token'));
}

my $boundary = 'XyZ';
my %multipart = ('Content-Type' => "multipart/form-data; boundary=$boundary");
my %urlencoded = ('Content-Type' => 'application/x-www-form-urlencoded');
sub multipart_body {
    my (%field) = @_;
    return join "\r\n",
        (map { ("--$boundary", qq{Content-Disposition: form-data; name="$_"}, '', $field{$_}) } sort keys %field),
        ("--$boundary", 'Content-Disposition: form-data; name="file"; filename="a.txt"',
            'Content-Type: text/plain', '', 'x' x 100),
        "--$boundary--", '';
}

# --- the middleware ---

subtest 'by default there is no form flow: a form post without the header is refused' => sub {
    my ($client, $token) = primed();
    $called = 0;
    is $client->post('/', form => { csrf_token => $token, title => 'hi' })->status, 403,
        'the field is not read';
    is $called, 0, 'the application is never called';
    is $client->post('/?read=stream', form => { title => 'hi' }, headers => { 'X-CSRF-Token' => $token })->text,
        'failure=none | stream=streams', 'the header passes, and the body is unread';
};

subtest 'with form_field, a form post without its token is refused here' => sub {
    my ($client, $token) = primed(form_field => 'csrf_token');
    is $client->post('/?read=stream', form => { title => 'hi' })->status, 403,
        'urlencoded without its token: refused by the middleware (t/middleware/csrf-form-check.t)';
    is $client->post('/?read=mstream', body => multipart_body(title => 'hi'), headers => \%multipart)->status, 403,
        'multipart: the same (t/middleware/csrf-multipart.t)';
};

subtest 'with form_field, every other failure is still refused' => sub {
    my ($client, $token) = primed(form_field => 'csrf_token');
    $called = 0;
    is $client->post('/', form => { csrf_token => $token }, headers => { 'X-CSRF-Token' => 'forged' })->status, 403,
        'a wrong header';
    is $client->post('/', form => { csrf_token => $token }, headers => { 'Sec-Fetch-Site' => 'cross-site' })->status, 403,
        'a cross-site form';
    is $client->post('/', json => { csrf_token => $token })->status, 403, 'a JSON body without the header';
    is client_with(form_field => 'csrf_token')->post('/', form => { csrf_token => 'guess' })->status, 403,
        'no stored token to match';
    is $called, 0, 'the application is never called';
};

subtest 'form_field must be a field name or undef; body_buffer is gone' => sub {
    for my $bad ('', []) {
        like dies { PAGI::Middleware::CSRF->new(form_field => $bad) },
            qr/\ACSRF form_field must be a field name, like csrf_token, or undef for no form flow/,
            'form_field => ' . (ref $bad ? 'a reference' : "''") . ' dies';
    }
    ok lives { PAGI::Middleware::CSRF->new(form_field => undef) }, 'undef lives';
    like dies { PAGI::Middleware::CSRF->new(body_buffer => sub {}) },
        qr/\ACSRF 'body_buffer' was removed: the form read is bounded by max_form_size/, 'body_buffer dies';
};

# An application that reads the body from $receive itself, as one written to
# the PAGI spec does, and answers with what it read.
async sub echo_body {
    my ($scope, $receive, $send) = @_;
    my $body = '';
    if ($scope->{method} ne 'GET') {
        while (1) {
            my $event = await $receive->();
            last unless $event->{type} eq 'http.request';
            $body .= $event->{body} // '';
            last unless $event->{more};
        }
    }
    await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
    await $send->({ type => 'http.response.body', body => "read: $body", more => 0 });
}

subtest 'an application reading $receive gets the body untouched' => sub {
    my $client = PAGI::Test::Client->new(app => PAGI::Middleware::CSRF->new(form_field => 'csrf_token')->wrap(\&echo_body));
    $client->get('/');
    my $token = $client->cookie('csrf_token');
    my $form = "csrf_token=$token&title=hi";
    is $client->post('/', body => $form, headers => \%urlencoded)->text, "read: $form", 'a urlencoded form';
    my $multipart = multipart_body(csrf_token => $token, title => 'hi');
    is $client->post('/', body => $multipart, headers => \%multipart)->text, "read: $multipart", 'a multipart form';
};

# --- csrf_protect ---

subtest 'csrf_protect: the right field passes, and the handler reads the same parse' => sub {
    my ($client, $token) = primed(form_field => 'csrf_token');
    my $res = $client->post('/protected?read=form,body,stream',
        form => { csrf_token => $token, title => "h\xc3\xa9" });    # UTF-8, as a browser sends it
    is $res->status, 200, 'passes';
    is $res->text, join(' | ', 'failure=none', "form=h\x{e9}", "body=csrf_token=$token&title=h%C3%A9",
        'stream=dies: Body already consumed; streaming not available'),
        'the middleware checked the field; the handler parses the replayed body itself';
};

subtest 'csrf_protect: a missing, empty or wrong field is refused before the handler' => sub {
    my ($client, $token) = primed(form_field => 'csrf_token');
    $called = 0;
    my $res = $client->post('/protected', form => { title => 'hi' });
    is [$res->status, $res->text], [403, 'CSRF token validation failed'], 'no field: the default refusal';
    is $client->post('/protected', form => { csrf_token => '' })->status, 403, 'an empty field';
    is $client->post('/protected', form => { csrf_token => 'forged' })->status, 403, 'a wrong field';
    is $client->post('/protected', json => { csrf_token => $token })->status, 403, 'a JSON body never gets this far';
    is $called, 0, 'the handler is never called';
};

subtest 'csrf_protect: a request that passed the middleware is not read again' => sub {
    my ($client, $token) = primed(form_field => 'csrf_token');
    is $client->post('/protected?read=stream', form => { title => 'hi' }, headers => { 'X-CSRF-Token' => $token })->text,
        'failure=none | stream=streams', 'the header passed: csrf_protect does not read the body';
    is $client->get('/protected?read=stream')->text, 'failure=none | stream=streams', 'a safe method';
};

subtest 'csrf_protect: a multipart form' => sub {
    my ($client, $token) = primed(form_field => 'csrf_token');
    my $res = $client->post('/protected?read=form,uploads',
        body => multipart_body(csrf_token => $token, title => 'hi'), headers => \%multipart);
    is [$res->status, $res->text], [200, 'failure=none | form=hi | uploads=1'], 'the right field passes, checked by the middleware';
    is $client->post('/protected', body => multipart_body(title => 'hi'), headers => \%multipart)->status, 403,
        'no field: refused';
    $res = $client->post('/protected', body => multipart_body(csrf_token => $token, big => 'x' x (1024 * 1024 + 10)),
        headers => \%multipart);
    is [$res->status, $res->text], [413, 'Request body too large'],
        'a field over max_form_size before the token (fields sort: big, then csrf_token): the middleware answers';
};

subtest 'csrf_protect: form_field names the field' => sub {
    my ($client, $token) = primed(form_field => 'authenticity_token');
    is $client->post('/protected', form => { authenticity_token => $token })->status, 200, 'another name is read';
    is $client->post('/protected', form => { csrf_token => $token })->status, 403, 'and the default name is not';
};

subtest 'csrf_protect: refuse answers, given the same Request' => sub {
    my ($client) = primed(form_field => 'csrf_token', refuse => response('JSON', { detail => 'nope' }, status => 403));
    is [map { $_->status, $_->text } $client->post('/protected', form => { csrf_token => 'forged' })],
        [403, '{"detail":"nope"}'], 'a Response';
    my ($reads) = primed(form_field => 'csrf_token', refuse => async sub {
        my ($request) = @_;
        my $form = await $request->form_params;
        return response('Text', 'refused ' . $form->get('title') . ': ' . csrf($request)->failure, status => 403);
    });
    is [map { $_->status, $_->text } $reads->post('/protected', form => { csrf_token => 'forged', title => 'hi' })],
        [403, 'refused hi: mismatch'], 'a Request handler, refusing for the middleware, reads the replayed form';
};

subtest 'csrf_protect: under session => 1 the field matches the session token' => sub {
    my $app = compose(
        routes     => [route('/' => csrf_protect(sub { response('Text', $_[0]->method eq 'GET' ? csrf($_[0])->token : 'saved') }),
            methods => ['GET', 'POST'])],
        middleware => [middleware('Session'), middleware('CSRF', session => 1, form_field => 'csrf_token')],
    );
    my $warnings = warnings { $app->to_app };
    ok !(grep { !/\APAGI::Middleware::Session: no store given/ } @$warnings),
        'nothing warns but the default session store';
    my $client = PAGI::Test::Client->new(app => $app);
    my $token = $client->get('/')->text;
    is $client->post('/', form => { csrf_token => $token })->text, 'saved', 'the session token in the field passes';
    is $client->post('/', form => {})->status, 403, 'a missing one is refused';
    $client->set_cookie(csrf_token => 'a' x 64);
    is $client->post('/', form => { csrf_token => 'a' x 64 })->status, 403,
        'a field matching a planted csrf_token cookie is refused';
};

subtest 'csrf_protect: every unsafe method reads the form' => sub {
    my ($client, $token) = primed(form_field => 'csrf_token');
    for my $method (qw(put patch delete)) {
        is $client->$method('/protected', form => { csrf_token => $token })->status, 200, uc($method) . ': passes';
        is $client->$method('/protected', form => { csrf_token => 'forged' })->status, 403, uc($method) . ': refused';
    }
};

subtest "csrf_protect: a malformed multipart body is the client's 400, answered by Compose" => sub {
    my ($client) = primed(form_field => 'csrf_token');
    my $res = $client->post('/protected', body => '', headers => \%multipart);
    is [$res->status, $res->text], [400, 'The multipart request body could not be parsed.'], 'an empty body: the middleware answers, in the parser\'s words';
};

subtest 'csrf_protect: the field, read as a form field' => sub {
    my ($client, $token) = primed(form_field => 'csrf_token');
    is $client->post('/protected', form => [[csrf_token => $token], [csrf_token => 'forged']])->status, 200,
        'a repeated field: the first value decides';
    is $client->post('/protected', form => [[csrf_token => 'forged'], [csrf_token => $token]])->status, 403,
        'whatever follows it';
    is $client->post('/protected', body => "csrf_token=$token",
        headers => { 'Content-Type' => 'Application/X-WWW-Form-Urlencoded; charset=UTF-8' })->status, 200,
        'the form media type in any case and with parameters';
    my $file = join "\r\n", "--$boundary",
        qq{Content-Disposition: form-data; name="csrf_token"; filename="token.txt"},
        'Content-Type: text/plain', '', $token, "--$boundary--", '';
    is $client->post('/protected', body => $file, headers => \%multipart)->status, 403,
        'a csrf_token file part is an upload, not the field';
    is $client->post('/protected', body => 'csrf_token=' . ('%FF' x 64), headers => \%urlencoded)->status, 403,
        'bytes that are not UTF-8 are a mismatch, not an error';
    is $client->post("/protected?csrf_token=$token", body => 'title=hi', headers => \%urlencoded)->status, 403,
        'a token in the query string is never read';
};

subtest 'csrf_protect needs the middleware with form_field, refusing' => sub {
    my $handler = csrf_protect(sub { response('Text', 'ran') });
    for my $case (['no CSRF middleware', []], ['no form_field', [middleware('CSRF')]],
                  ['refuse => 0', [middleware('CSRF', form_field => 'csrf_token', refuse => 0)]]) {
        my ($label, $middleware) = @$case;
        my $client = PAGI::Test::Client->new(app => compose(
            routes => [route('/' => $handler, methods => ['GET', 'POST'])], middleware => $middleware));
        my $res;
        like warnings { $res = $client->get('/') },
            [qr/csrf_protect needs PAGI::Middleware::CSRF with form_field, refusing/], "$label: it says so";
        is $res->status, 500, "$label: a 500";
    }
    like dies { csrf_protect('report') }, qr/\Acsrf_protect needs a handler coderef/, 'a handler coderef';
};

done_testing;
