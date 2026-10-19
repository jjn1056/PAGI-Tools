#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use File::Temp qw(tempfile);
use Time::HiRes ();

use lib 'lib';
use PAGI::Test::Client;

# Simple test app
my $app = async sub {
    my ($scope, $receive, $send) = @_;

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });

    await $send->({
        type => 'http.response.body',
        body => 'Hello World',
        more => 0,
    });
};

subtest 'basic GET request' => sub {
    my $client = PAGI::Test::Client->new(app => $app);
    my $res = $client->get('/');

    is $res->status, 200, 'status 200';
    is $res->text, 'Hello World', 'body';
    is $res->header('content-type'), 'text/plain', 'content-type';
};

subtest 'captures filehandle response bodies' => sub {
    my $fh_app = async sub {
        my ($scope, $receive, $send) = @_;
        my $content = "Hello from filehandle";

        open my $fh, '<', \$content or die "Cannot open scalar handle: $!";

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [
                ['content-type', 'text/plain'],
                ['content-length', length($content)],
            ],
        });

        await $send->({
            type => 'http.response.body',
            fh   => $fh,
        });

        close $fh;
    };

    my $client = PAGI::Test::Client->new(app => $fh_app);
    my $res = $client->get('/');

    is $res->status, 200, 'status 200';
    is $res->content, 'Hello from filehandle', 'filehandle body captured';
};

subtest 'captures file response bodies' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    print {$fh} 'Hello from file';
    close $fh;

    my $file_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            file => $path,
        });
    };

    my $client = PAGI::Test::Client->new(app => $file_app);
    my $res = $client->get('/');

    is $res->status, 200, 'status 200';
    is $res->content, 'Hello from file', 'file body captured';
};

subtest 'captures filehandle response offset and length' => sub {
    my $fh_app = async sub {
        my ($scope, $receive, $send) = @_;
        my $content = '0123456789';

        open my $fh, '<', \$content or die "Cannot open scalar handle: $!";

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type   => 'http.response.body',
            fh     => $fh,
            offset => 2,
            length => 4,
        });

        close $fh;
    };

    my $client = PAGI::Test::Client->new(app => $fh_app);
    my $res = $client->get('/');

    is $res->content, '2345', 'filehandle offset/length respected';
};

subtest 'captures file response offset and length' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    print {$fh} 'abcdefghij';
    close $fh;

    my $file_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type   => 'http.response.body',
            file   => $path,
            offset => 3,
            length => 3,
        });
    };

    my $client = PAGI::Test::Client->new(app => $file_app);
    my $res = $client->get('/');

    is $res->content, 'def', 'file offset/length respected';
};

subtest 'HEAD suppresses response body transport semantics' => sub {
    my $head_app = async sub {
        my ($scope, $receive, $send) = @_;
        my $content = 'Body that HEAD must suppress';

        open my $fh, '<', \$content or die "Cannot open scalar handle: $!";

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [
                ['content-type', 'text/plain'],
                ['content-length', length($content)],
            ],
        });

        await $send->({
            type => 'http.response.body',
            fh   => $fh,
        });

        close $fh;
    };

    my $client = PAGI::Test::Client->new(app => $head_app);

    is $client->get('/')->content, 'Body that HEAD must suppress', 'GET still returns body';
    is $client->head('/')->content, '', 'HEAD response body suppressed';
};

subtest 'duplicate response.start fails the send; first response stands' => sub {
    my $dup_err;
    my $dup_start_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 201,
            headers => [['content-type', 'text/plain']],
        });

        eval {
            await $send->({
                type    => 'http.response.start',
                status  => 500,
                headers => [['content-type', 'application/json']],
            });
            1;
        } or do { $dup_err = $@ };

        await $send->({
            type => 'http.response.body',
            body => 'first start wins',
        });
    };

    my $client = PAGI::Test::Client->new(app => $dup_start_app);
    my $res = $client->get('/');

    ok $dup_err, 'the duplicate start failed its send Future';
    like $dup_err, qr/duplicate/i, 'error names the duplicate start';
    is $res->status, 201, 'first status preserved';
    is $res->header('content-type'), 'text/plain', 'first headers preserved';
    is $res->content, 'first start wins', 'body still captured';
};

subtest 'body events after response completion fail the send' => sub {
    my $extra_err;
    my $extra_body_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => 'done',
            more => 0,
        });

        eval {
            await $send->({
                type => 'http.response.body',
                body => 'ignored',
                more => 0,
            });
            1;
        } or do { $extra_err = $@ };
    };

    my $client = PAGI::Test::Client->new(app => $extra_body_app);
    my $res = $client->get('/');

    ok $extra_err, 'the post-completion body send failed its Future';
    like $extra_err, qr/complete/i, 'error names the already-complete response';
    is $res->status, 200, 'first response status stands';
    is $res->content, 'done', 'body after completion ignored';
};

subtest 'GET with path' => sub {
    my $path_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Path: $scope->{path}",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $path_app);
    my $res = $client->get('/users/123');

    is $res->text, 'Path: /users/123', 'path passed to app';
};

subtest 'POST with JSON body' => sub {
    my $json_app = async sub {
        my ($scope, $receive, $send) = @_;

        # Read request body
        my $event = await $receive->();
        my $body = $event->{body};

        require JSON::MaybeXS;
        my $data = JSON::MaybeXS::decode_json($body);

        await $send->({
            type    => 'http.response.start',
            status  => 201,
            headers => [['content-type', 'application/json']],
        });

        await $send->({
            type => 'http.response.body',
            body => JSON::MaybeXS::encode_json({ id => 1, name => $data->{name} }),
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $json_app);
    my $res = $client->post('/users', json => { name => 'John' });

    is $res->status, 201, 'status 201';
    is $res->json->{id}, 1, 'got id';
    is $res->json->{name}, 'John', 'got name back';
};

subtest 'POST with form data' => sub {
    my $form_app = async sub {
        my ($scope, $receive, $send) = @_;

        my $event = await $receive->();
        my $body = $event->{body};

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Form: $body",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $form_app);
    my $res = $client->post('/login', form => { user => 'admin', pass => 'secret' });

    like $res->text, qr/user=admin/, 'form has user';
    like $res->text, qr/pass=secret/, 'form has pass';
};

subtest 'PUT and PATCH methods' => sub {
    my $method_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Method: $scope->{method}",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $method_app);

    is $client->put('/resource')->text, 'Method: PUT', 'PUT works';
    is $client->patch('/resource')->text, 'Method: PATCH', 'PATCH works';
    is $client->options('/resource')->text, 'Method: OPTIONS', 'OPTIONS works';
};

subtest 'QUERY sends the path, query and headers as get does, and a body as post does' => sub {
    my $echo_app = async sub {
        my ($scope, $receive, $send) = @_;
        my $event = await $receive->();
        my %header = map { lc($_->[0]) => $_->[1] } @{ $scope->{headers} };

        require JSON::MaybeXS;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'application/json']],
        });
        await $send->({
            type => 'http.response.body',
            body => JSON::MaybeXS::encode_json({
                method       => $scope->{method},
                path         => $scope->{path},
                query_string => $scope->{query_string},
                token        => $header{'x-token'},
                content_type => $header{'content-type'},
                body         => $event->{body},
            }),
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $echo_app);

    is $client->query('/search?page=2', query => { q => 'perl' },
        headers => { 'X-Token' => 'abc' }, json => { where => 'title' })->json,
        {
            method       => 'QUERY',
            path         => '/search',
            query_string => 'page=2&q=perl',
            token        => 'abc',
            content_type => 'application/json',
            body         => '{"where":"title"}',
        },
        'QUERY with a query string, a header and a JSON body';

    my $res = $client->query('/search', body => 'select title');
    is [$res->json->{method}, $res->json->{body}], ['QUERY', 'select title'],
        'QUERY with a raw body';
};

subtest 'query parameter encoding' => sub {
    my $query_app = async sub {
        my ($scope, $receive, $send) = @_;

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Query: $scope->{query_string}",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $query_app);

    # Test special characters are encoded
    my $res = $client->get('/test', query => { 'key with spaces' => 'value&with=special' });
    like $res->text, qr/key%20with%20spaces/, 'key is URL encoded';
    like $res->text, qr/value%26with%3Dspecial/, 'value is URL encoded';

    # Test query params merge with path query
    $res = $client->get('/test?existing=param', query => { foo => 'bar' });
    like $res->text, qr/existing=param/, 'path query preserved';
    like $res->text, qr/foo=bar/, 'option query added';
};

subtest 'cookies persist across requests' => sub {
    my $cookie_app = async sub {
        my ($scope, $receive, $send) = @_;

        # Check for cookie header
        my $has_cookie = '';
        for my $h (@{$scope->{headers}}) {
            if (lc($h->[0]) eq 'cookie') {
                $has_cookie = $h->[1];
            }
        }

        my @resp_headers = (['content-type', 'text/plain']);
        my $body;

        if ($scope->{path} eq '/login') {
            push @resp_headers, ['set-cookie', 'session=abc123'];
            $body = 'logged in';
        } else {
            $body = $has_cookie ? "Cookie: $has_cookie" : "No cookie";
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => \@resp_headers,
        });

        await $send->({
            type => 'http.response.body',
            body => $body,
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $cookie_app);

    # Before login - no cookie
    is $client->get('/dashboard')->text, 'No cookie', 'no cookie initially';

    # Login sets cookie
    is $client->get('/login')->text, 'logged in', 'login response';

    # After login - cookie sent
    like $client->get('/dashboard')->text, qr/session=abc123/, 'cookie persisted';

    # Cookie accessors
    is $client->cookie('session'), 'abc123', 'cookie() accessor';
    ok exists $client->cookies->{session}, 'cookies() hashref';

    # Clear cookies
    $client->clear_cookies;
    is $client->get('/dashboard')->text, 'No cookie', 'cookies cleared';
};

subtest 'set_cookie manually' => sub {
    my $echo_app = async sub {
        my ($scope, $receive, $send) = @_;

        my $cookie = '';
        for my $h (@{$scope->{headers}}) {
            $cookie = $h->[1] if lc($h->[0]) eq 'cookie';
        }

        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });

        await $send->({
            type => 'http.response.body',
            body => "Cookie: $cookie",
            more => 0,
        });
    };

    my $client = PAGI::Test::Client->new(app => $echo_app);
    $client->set_cookie('theme', 'dark');

    like $client->get('/')->text, qr/theme=dark/, 'manual cookie sent';
};

subtest 'a streaming producer that awaits real I/O completes' => sub {
    require Future::IO;
    require PAGI::Compose;
    require PAGI::Response;
    require PAGI::Routing;

    my $app = PAGI::Compose::compose(routes => [
        PAGI::Routing::route('/stream' => async sub {
            my ($request) = @_;
            return PAGI::Response::response('Stream', async sub {
                my ($writer) = @_;
                for my $n (1 .. 3) {
                    await $writer->write("tick $n\n");
                    await Future::IO->sleep(0.05);
                }
            });
        }),
    ]);

    my $res = PAGI::Test::Client->new(app => $app)->get('/stream');
    is($res->status, 200, 'the stream completes');
    is($res->content, "tick 1\ntick 2\ntick 3\n", 'with every chunk');
};

subtest 'a handler that awaits real I/O completes' => sub {
    require Future::IO;
    my $slow = async sub {
        my ($scope, $receive, $send) = @_;
        await Future::IO->sleep(0.05);
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({ type => 'http.response.body', body => 'slept', more => 0 });
    };
    is(PAGI::Test::Client->new(app => $slow)->get('/')->content, 'slept',
        'the loop is driven');
};

subtest 'a request that never completes fails at the harness timeout' => sub {
    require Future::IO;
    local $PAGI::Test::_Drive::TIMEOUT = 0.3;
    my $stuck = async sub { await Future::IO->sleep(3) };

    my $started = Time::HiRes::time();
    like(dies { PAGI::Test::Client->new(app => $stuck)->get('/') },
        qr/PAGI request did not complete within 0\.3 seconds/,
        'the client dies with the timeout');
    ok(Time::HiRes::time() - $started < 2, 'at the timeout, not after the app\'s 3s');
};

subtest 'an app awaiting a Future subclass that real I/O resolves completes' => sub {
    require Future::IO;
    { package PAGITest::SubclassFuture; our @ISA = ('Future'); }
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $ready = PAGITest::SubclassFuture->new;
        my $timer = Future::IO->sleep(0.1)->on_done(sub { $ready->done });
        await $ready;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({ type => 'http.response.body', body => 'ready', more => 0 });
    };
    is(PAGI::Test::Client->new(app => $app)->get('/')->content, 'ready',
        'the loop is driven whatever class the app\'s Future has');
};

done_testing;
