#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use File::Spec;
use File::Temp qw(tempdir);
use Cwd 'abs_path';
use Scalar::Util qw(refaddr);

use lib 'lib';

use PAGI::App::File;
use PAGI::Middleware::Static;
use PAGI::Test::Client;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

sub capture_events {
    my ($app, $scope) = @_;
    my @events;
    run_async(async sub {
        await Future->wrap($app->(
            $scope,
            sub { return Future->done({ type => 'http.disconnect' }) },
            sub { push @events, $_[0]; return Future->done },
        ));
    });
    return \@events;
}

sub event_header {
    my ($event, $name) = @_;
    for my $header (@{$event->{headers} // []}) {
        return $header->[1] if lc($header->[0]) eq lc($name);
    }
    return;
}

sub sentinel_app {
    my ($calls, $label) = @_;
    return sub {
        my ($scope, $receive, $send) = @_;
        push @$calls, $scope;
        if ($scope->{type} ne 'http') {
            $send->({ type => 'websocket.accept' });
            $send->({ type => 'websocket.send', text => $label });
            $send->({ type => 'websocket.close', code => 1000 });
            return $label;
        }
        $send->({
            type => 'http.response.start', status => 298,
            headers => [['content-type', 'text/plain']],
        });
        $send->({
            type => 'http.response.body', body => $label, more => 0,
        });
        return $label;
    };
}

sub write_test_file {
    my ($path, $contents) = @_;
    open my $file, '>', $path or die "cannot create $path: $!";
    print {$file} $contents;
    close $file or die "cannot close $path: $!";
    return;
}

{
    package Local::StaticProbeFailure;

    sub locate { die "simulated static probe failure\n" }
    sub serve  { die "serve must not follow a failed static probe\n" }
}

# Get absolute path to test files
my $test_root = abs_path('t/static_test_files');

subtest 'Static delegates owned errors to File without changing seams' => sub {
    my $inner = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type => 'http.response.start', status => 209,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body', body => 'inner response', more => 0,
        });
    };
    my $mw = PAGI::Middleware::Static->new(root => $test_root);
    my $client = PAGI::Test::Client->new(
        app => $mw->wrap($inner), raise_app_exceptions => 1,
    );

    my $missing = $client->get('/private/missing.txt',
        headers => { Accept => 'application/problem+json' });
    is($missing->status, 404, 'owned missing file keeps its status');
    is($missing->content_type, 'application/problem+json',
        'owned missing file negotiates a problem response');
    is($missing->json, {
        type   => 'about:blank',
        title  => 'Not Found',
        status => 404,
        detail => 'The requested resource was not found.',
    }, 'Static uses the safe stock missing body');
    unlike($missing->content, qr/private|missing\.txt|\Q$test_root\E/,
        'Static missing response does not disclose paths');
    is($missing->header('Cache-Control'), 'no-store',
        'Static missing response is not stored');
    is($missing->header('Vary'), 'Accept',
        'Static missing response records negotiation');

    my $forbidden = $client->get('/../../../etc/passwd',
        headers => { Accept => 'text/html' });
    is($forbidden->status, 403, 'unsafe path keeps its forbidden status');
    is($forbidden->content_type, 'text/html; charset=utf-8',
        'unsafe path can negotiate stock HTML');
    unlike($forbidden->text, qr/etc\/passwd|\Q$test_root\E/,
        'forbidden HTML does not disclose paths');

    my $text_missing = $client->get('/absent.txt',
        headers => { Accept => 'text/plain' });
    is($text_missing->content_type, 'text/plain; charset=utf-8',
        'owned missing response can negotiate stock text');
    like($text_missing->text, qr/^404 Not Found\n/,
        'text response identifies the stock status safely');

    my $range = $client->get('/hello.txt', headers => {
        Accept => 'application/problem+json', Range => 'bytes=1000-2000',
    });
    is($range->status, 416, 'owned invalid range keeps its status');
    is($range->header('Content-Range'), 'bytes */12',
        'owned invalid range reports the known representation length');

    my $full = $client->get('/hello.txt');
    is($full->status, 200, 'full static request still succeeds');
    is($full->content, "Hello World\n", 'full static bytes are unchanged');

    my $head = $client->head('/hello.txt');
    is($head->status, 200, 'static HEAD still succeeds');
    is($head->content, '', 'static HEAD remains bodyless');
    is($head->content_length, 12, 'static HEAD retains representation length');

    my $partial = $client->get('/hello.txt',
        headers => { Range => 'bytes=0-4' });
    is($partial->status, 206, 'static valid range still succeeds');
    is($partial->content, 'Hello', 'static range bytes are unchanged');
    is($partial->header('Content-Range'), 'bytes 0-4/12',
        'static range metadata is unchanged');

    my $cached = $client->get('/hello.txt',
        headers => { 'If-None-Match' => $full->header('ETag') });
    is($cached->status, 304, 'static matching ETag still produces 304');
    is($cached->content, '', 'static 304 remains bodyless');

    my $passing = PAGI::Middleware::Static->new(
        root => $test_root, pass_through => 1,
    );
    my $passing_client = PAGI::Test::Client->new(
        app => $passing->wrap($inner), raise_app_exceptions => 1,
    );
    my $passed = $passing_client->get('/still-missing.txt',
        headers => { Accept => 'application/problem+json' });
    is($passed->status, 209, 'pass-through status remains inner-app owned');
    is($passed->content_type, 'text/plain',
        'pass-through content type remains inner-app owned');
    is($passed->content, 'inner response',
        'pass-through body remains inner-app owned');
};

# =============================================================================
# Test: Static middleware serves files with correct MIME types
# =============================================================================

subtest 'Static middleware serves HTML with correct MIME type' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 404,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Not from static',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/index.html', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200';

    my $ct;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-type') {
            $ct = $h->[1];
            last;
        }
    }
    is $ct, 'text/html', 'Content-Type is text/html';
    # Middleware now uses file => instead of body => for server to handle
    like $sent[1]{file}, qr/index\.html$/, 'file path points to index.html';
};

subtest 'Static middleware serves JavaScript with correct MIME type' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/app.js', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200';

    my $ct;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-type') {
            $ct = $h->[1];
            last;
        }
    }
    is $ct, 'application/javascript', 'Content-Type is application/javascript';
};

subtest 'Static middleware serves CSS with correct MIME type' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/style.css', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    my $ct;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-type') {
            $ct = $h->[1];
            last;
        }
    }
    is $ct, 'text/css', 'Content-Type is text/css';
};

# =============================================================================
# Test: Static middleware prevents path traversal attacks
# =============================================================================

subtest 'Static middleware prevents path traversal with ../' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/../../../etc/passwd', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 403, 'status is 403 Forbidden';
};

subtest 'Static middleware prevents encoded path traversal' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/%2e%2e/%2e%2e/etc/passwd', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    # Should be either 403 or 404 (not 200)
    ok $sent[0]{status} >= 400, 'status is 4xx (path traversal blocked)';
};

subtest 'Static middleware allows valid subdirectory access' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/subdir/file.txt', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200 for valid subdirectory';
    # Middleware now uses file => instead of body => for server to handle
    like $sent[1]{file}, qr/subdir\/file\.txt$/, 'file path points to subdir/file.txt';
};

# =============================================================================
# Test: Static middleware supports ETag and 304 responses
# =============================================================================

subtest 'Static middleware returns ETag header' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/hello.txt', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    my $etag;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'etag') {
            $etag = $h->[1];
            last;
        }
    }

    ok $etag, 'ETag header present';
    like $etag, qr/^"[a-f0-9]+"$/, 'ETag format is quoted hex string';
};

subtest 'Static middleware returns 304 for matching ETag' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    # First request to get ETag
    my @sent1;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/hello.txt', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent1, $event },
        );
    });

    my $etag;
    for my $h (@{$sent1[0]{headers}}) {
        if (lc($h->[0]) eq 'etag') {
            $etag = $h->[1];
            last;
        }
    }

    # Second request with If-None-Match
    my @sent2;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/hello.txt',
                method  => 'GET',
                headers => [['if-none-match', $etag]],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent2, $event },
        );
    });

    is $sent2[0]{status}, 304, 'status is 304 Not Modified';
    is $sent2[1]{body}, '', 'body is empty for 304';
};

# =============================================================================
# Test: Static middleware supports Range requests
# =============================================================================

subtest 'Static middleware supports Range requests' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/hello.txt',
                method  => 'GET',
                headers => [['range', 'bytes=0-4']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 206, 'status is 206 Partial Content';

    my ($content_range, $content_length);
    for my $h (@{$sent[0]{headers}}) {
        my $name = lc($h->[0]);
        $content_range = $h->[1] if $name eq 'content-range';
        $content_length = $h->[1] if $name eq 'content-length';
    }

    ok $content_range, 'Content-Range header present';
    like $content_range, qr/^bytes 0-4\//, 'Content-Range format is correct';
    is $content_length, 5, 'Content-Length is 5 bytes';
    # Middleware now uses file => with offset/length for server to handle range
    like $sent[1]{file}, qr/hello\.txt$/, 'file path points to hello.txt';
    is $sent[1]{offset}, 0, 'offset is 0';
    is $sent[1]{length}, 5, 'length is 5 bytes';
};

subtest 'Static middleware handles suffix range' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/hello.txt',
                method  => 'GET',
                headers => [['range', 'bytes=-5']],  # Last 5 bytes
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 206, 'status is 206 for suffix range';
    is event_header($sent[0], 'Content-Range'), 'bytes 7-11/12',
        'suffix range reports the exact final five bytes';
    is event_header($sent[0], 'Content-Length'), 5,
        'suffix range reports the exact selected length';
    is $sent[1]{offset}, 7, 'suffix range delegates the exact file offset';
    is $sent[1]{length}, 5, 'suffix range delegates the exact file length';
};

subtest 'Static middleware returns 416 for invalid range' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/hello.txt',
                method  => 'GET',
                headers => [['range', 'bytes=1000-2000']],  # Beyond file size
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 416, 'status is 416 Range Not Satisfiable';
};

# =============================================================================
# Test: Other Static middleware features
# =============================================================================

subtest 'Static middleware returns 404 for missing files' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/nonexistent.txt', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 404, 'status is 404 for missing file';
};

subtest 'Static middleware pass_through falls back to app' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root, pass_through => 1);

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'From app',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/nonexistent.txt', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok $app_called, 'inner app was called';
    is $sent[1]{body}, 'From app', 'response from inner app';
};

subtest 'Static middleware path coderef can rewrite via return value' => sub {
    my $mw = PAGI::Middleware::Static->new(
        root => $test_root,
        path => sub {
            my ($path) = @_;
            return unless $path =~ m{^/static/};
            $path =~ s{^/static}{/};
            return $path;
        },
    );

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/static/hello.txt', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200 for rewritten path';
    like $sent[1]{file}, qr/hello\.txt$/, 'file path points to hello.txt';
};

subtest 'Static middleware path coderef supports in-place rewrite without leading slash' => sub {
    my $mw = PAGI::Middleware::Static->new(
        root => $test_root,
        path => sub {
            $_[0] =~ s{^/static/}{};
            return 1;
        },
    );

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/static/hello.txt', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200 after normalized rewrite';
    like $sent[1]{file}, qr/hello\.txt$/, 'file path points to hello.txt';
};

subtest 'Static middleware serves index file for directory' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200 for directory with index';
    # Middleware now uses file => instead of body => for server to handle
    like $sent[1]{file}, qr/index\.html$/, 'file path points to index.html';
};

subtest 'Static middleware handles HEAD requests' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/hello.txt', method => 'HEAD', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200 for HEAD';

    my $cl;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-length') {
            $cl = $h->[1];
            last;
        }
    }

    ok $cl > 0, 'Content-Length header present';
    is $sent[1]{body}, '', 'body is empty for HEAD request';
};

subtest 'Static middleware skips non-GET/HEAD requests' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'POST handled',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/hello.txt', method => 'POST', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    ok $app_called, 'inner app called for POST';
    is $sent[1]{body}, 'POST handled', 'POST passed through to app';
};

# =============================================================================
# Test: handle_ranges option
# =============================================================================

subtest 'Static middleware handle_ranges => 0 ignores Range header' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root, handle_ranges => 0);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/hello.txt',
                method  => 'GET',
                headers => [['range', 'bytes=0-4']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 200, 'status is 200 (not 206) when handle_ranges => 0';

    # Verify no Content-Range header
    my $content_range;
    for my $h (@{$sent[0]{headers}}) {
        $content_range = $h->[1] if lc($h->[0]) eq 'content-range';
    }
    ok !$content_range, 'No Content-Range header when handle_ranges => 0';

    # Verify full file is returned (no offset/length)
    ok !defined $sent[1]{offset}, 'No offset in file response';
    ok !defined $sent[1]{length}, 'No length in file response';
    like $sent[1]{file}, qr/hello\.txt$/, 'Full file path returned';
};

subtest 'Static middleware handle_ranges => 1 (default) honors Range header' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root, handle_ranges => 1);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/hello.txt',
                method  => 'GET',
                headers => [['range', 'bytes=0-4']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 206, 'status is 206 when handle_ranges => 1';

    my $content_range;
    for my $h (@{$sent[0]{headers}}) {
        $content_range = $h->[1] if lc($h->[0]) eq 'content-range';
    }
    ok $content_range, 'Content-Range header present';
    like $content_range, qr/^bytes 0-4\//, 'Content-Range format is correct';

    # Verify partial file with offset/length
    is $sent[1]{offset}, 0, 'offset is 0';
    is $sent[1]{length}, 5, 'length is 5 bytes';
};

subtest 'Static middleware default handle_ranges honors Range header' => sub {
    # No handle_ranges specified - should default to 1
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type    => 'http',
                path    => '/hello.txt',
                method  => 'GET',
                headers => [['range', 'bytes=0-4']],
            },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 206, 'default behavior honors Range header (206)';
};

# =============================================================================
# Test: Double URL-decoding prevention
# =============================================================================

subtest 'Static middleware does not double URL-decode paths' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);

    my $app = async sub { };
    my $wrapped = $mw->wrap($app);

    # Simulate a path that the server has already decoded from %252e%252e to %2e%2e.
    # The middleware must NOT decode this again into ".." which would enable traversal.
    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/%2e%2e/etc/passwd', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    # With no double-decode, %2e%2e stays literal - file won't exist, so 404 (not 403 from traversal)
    is $sent[0]{status}, 404,
        'double-encoded traversal text remains a literal missing path';
};

subtest 'eligibility and pass-through preserve the original downstream scope' => sub {
    my $root = tempdir(CLEANUP => 1);
    write_test_file(File::Spec->catfile($root, 'served.txt'), 'served');
    my $empty = File::Spec->catdir($root, 'empty');
    mkdir $empty or die "cannot create $empty: $!";

    my @cases = (
        [
            'non-HTTP scope',
            PAGI::Middleware::Static->new(root => $root),
            { type => 'websocket', path => '/served.txt' },
        ],
        [
            'matching POST',
            PAGI::Middleware::Static->new(root => $root),
            {
                type => 'http', method => 'POST', path => '/served.txt',
                headers => [],
            },
        ],
        [
            'unmatched path',
            PAGI::Middleware::Static->new(
                root => $root, path => qr{^/assets/},
            ),
            {
                type => 'http', method => 'GET', path => '/served.txt',
                headers => [],
            },
        ],
        [
            'missing pass-through',
            PAGI::Middleware::Static->new(
                root => $root, pass_through => 1,
            ),
            {
                type => 'http', method => 'GET', path => '/missing.txt',
                headers => [],
            },
        ],
        [
            'indexless directory pass-through',
            PAGI::Middleware::Static->new(
                root => $root, pass_through => 1,
            ),
            {
                type => 'http', method => 'GET', path => '/empty',
                headers => [],
            },
        ],
    );

    for my $case (@cases) {
        my ($label, $mw, $scope) = @$case;
        my @calls;
        my $events = capture_events(
            $mw->wrap(sentinel_app(\@calls, $label)), $scope,
        );
        is(scalar @calls, 1, "$label reaches the inner app exactly once");
        is(refaddr($calls[0]), refaddr($scope),
            "$label preserves scope identity");
        is($calls[0]{path}, $scope->{path},
            "$label preserves the original request path");
        if ($scope->{type} eq 'http') {
            is($events->[0]{status}, 298,
                "$label keeps the sentinel response status");
            is($events->[1]{body}, $label,
                "$label keeps the sentinel response body");
        }
        else {
            is($events->[0], {
                type => 'websocket.accept',
            }, "$label keeps the protocol sentinel acceptance");
            is($events->[1], {
                type => 'websocket.send', text => $label,
            }, "$label keeps the protocol sentinel event");
            is($events->[2], {
                type => 'websocket.close', code => 1000,
            }, "$label keeps the protocol sentinel completion");
        }
    }

    for my $path ('/missing.txt', '/empty') {
        my @calls;
        my $scope = {
            type => 'http', method => 'GET', path => $path, headers => [],
        };
        my $events = capture_events(
            PAGI::Middleware::Static->new(root => $root)
                ->wrap(sentinel_app(\@calls, 'must not pass')),
            $scope,
        );
        is($events->[0]{status}, 404, "$path is an owned 404");
        is(scalar @calls, 0, "$path does not reach the inner app");
    }
};

subtest 'hidden and unsafe paths use the shared File policy' => sub {
    my $root = tempdir(CLEANUP => 1);
    write_test_file(File::Spec->catfile($root, '.secret'), 'secret');
    write_test_file(File::Spec->catfile($root, 'visible.txt'), 'visible');

    my @hidden_calls;
    my $hidden_scope = {
        type => 'http', method => 'GET', path => '/.secret', headers => [],
    };
    my $hidden = capture_events(
        PAGI::Middleware::Static->new(
            root => $root, pass_through => 1,
        )->wrap(sentinel_app(\@hidden_calls, 'hidden passed')),
        $hidden_scope,
    );
    is($hidden->[0]{status}, 403, 'hidden paths are forbidden by default');
    is(scalar @hidden_calls, 0,
        'a hidden forbidden result never passes through');

    my $allowed = capture_events(
        PAGI::Middleware::Static->new(
            root => $root, allow_hidden => 1,
        )->wrap(sub { die 'allowed hidden file reached inner app' }),
        { %$hidden_scope },
    );
    is($allowed->[0]{status}, 200, 'allow_hidden permits the hidden file');
    like($allowed->[1]{file}, qr/\.secret\z/,
        'allowed hidden response identifies the hidden file');

    for my $case (
        ['traversal', '/../visible.txt'],
        ['mixed separators', '/nested\\..\\visible.txt'],
    ) {
        my ($label, $path) = @$case;
        my @calls;
        my $events = capture_events(
            PAGI::Middleware::Static->new(
                root => $root, pass_through => 1,
            )->wrap(sentinel_app(\@calls, "$label passed")),
            {
                type => 'http', method => 'GET', path => $path, headers => [],
            },
        );
        is($events->[0]{status}, 403,
            "$label is forbidden with pass_through enabled");
        is(scalar @calls, 0, "$label never reaches the inner app");
    }
};

subtest 'rewrites are local and preserve the caller scope' => sub {
    my $scope = {
        type => 'http', method => 'GET', path => '/assets/hello.txt',
        headers => [],
    };
    my $mw = PAGI::Middleware::Static->new(
        root => $test_root,
        path => sub {
            my ($path) = @_;
            return unless $path =~ s{^/assets}{};
            return $path;
        },
    );
    my $events = capture_events(
        $mw->wrap(sub { die 'rewritten file reached inner app' }), $scope,
    );

    is($events->[0]{status}, 200, 'rewritten local path serves the file');
    like($events->[1]{file}, qr/hello\.txt\z/,
        'the rewritten local path selects hello.txt');
    is($scope->{path}, '/assets/hello.txt',
        'serving the rewrite does not mutate the original scope path');

    my $numeric_root = tempdir(CLEANUP => 1);
    write_test_file(File::Spec->catfile($numeric_root, '2'), 'two');
    my $numeric_scope = {
        type => 'http', method => 'GET', path => '/original', headers => [],
    };
    my $numeric_events = capture_events(
        PAGI::Middleware::Static->new(
            root => $numeric_root, path => sub { return 2 },
        )->wrap(sub { die 'numeric rewrite reached inner app' }),
        $numeric_scope,
    );
    is($numeric_events->[0]{status}, 200,
        'a true scalar other than exact 1 is a rewritten path');
    like($numeric_events->[1]{file}, qr{/2\z},
        'the non-1 true scalar selects its rewritten file');
    is($numeric_scope->{path}, '/original',
        'a scalar rewrite also leaves the original scope path unchanged');
};

subtest 'Static responses are byte-for-byte File-engine responses' => sub {
    my $root = tempdir(CLEANUP => 1);
    write_test_file(File::Spec->catfile($root, 'hello.txt'), "Hello World\n");
    write_test_file(File::Spec->catfile($root, 'opaque.unknown'), 'opaque');
    my $file = PAGI::App::File->new(root => $root);
    my $static = PAGI::Middleware::Static->new(root => $root);
    my $file_app = $file->to_app;
    my $static_app = $static->wrap(
        sub { die 'existing static file reached inner app' },
    );

    my $scope_for = sub {
        my ($method, $headers, $path) = @_;
        $path //= '/hello.txt';
        return {
            type => 'http', method => $method, path => $path,
            raw_path => $path, root_path => '',
            headers => $headers // [], path_params => {},
        };
    };

    my $direct = capture_events($file_app, $scope_for->('GET'));
    my $wrapped = capture_events($static_app, $scope_for->('GET'));
    is($wrapped->[0]{status}, $direct->[0]{status},
        'full response status matches File');
    for my $header (qw(Content-Type Content-Length ETag)) {
        is(event_header($wrapped->[0], $header),
            event_header($direct->[0], $header),
            "full response $header matches File");
    }
    is($wrapped->[1], $direct->[1],
        'full response file event matches File exactly');
    ok(exists $wrapped->[1]{file}, 'successful raw body uses a file event');
    ok(!exists $wrapped->[1]{fh}, 'successful raw body has no filehandle');
    ok(!exists $wrapped->[1]{body},
        'successful raw body has no in-memory body');

    my $etag = event_header($direct->[0], 'ETag');
    my $conditional_headers = [['if-none-match', $etag]];
    my $direct_cached = capture_events(
        $file_app, $scope_for->('GET', $conditional_headers),
    );
    my $wrapped_cached = capture_events(
        $static_app, $scope_for->('GET', $conditional_headers),
    );
    is($wrapped_cached, $direct_cached,
        'matching ETag produces the same 304 response as File');

    my $range_headers = [['range', 'bytes=0-4']];
    my $direct_range = capture_events(
        $file_app, $scope_for->('GET', $range_headers),
    );
    my $wrapped_range = capture_events(
        $static_app, $scope_for->('GET', $range_headers),
    );
    is($wrapped_range->[0]{status}, 206, 'Static retains range status');
    for my $header (qw(Content-Type Content-Length Content-Range ETag)) {
        is(event_header($wrapped_range->[0], $header),
            event_header($direct_range->[0], $header),
            "range response $header matches File");
    }
    is($wrapped_range->[1], $direct_range->[1],
        'range file event matches File exactly');

    for my $case (
        ['bytes=-5', 206],
        ['bytes=-0', 416],
        ['bytes=-', 416],
        ['bytes=0-1,8-9', 416],
        ['junkbytes=0-1', 416],
    ) {
        my ($range, $status) = @$case;
        my $headers = [['range', $range]];
        my $direct_case = capture_events(
            $file_app, $scope_for->('GET', $headers),
        );
        my $wrapped_case = capture_events(
            $static_app, $scope_for->('GET', $headers),
        );
        is($wrapped_case, $direct_case,
            "Static exactly preserves File handling for $range");
        is($wrapped_case->[0]{status}, $status,
            "$range retains the strict shared status");
    }

    for my $case (
        ['empty Range field', [['range', '']]],
        ['Unicode digits', [['range', "bytes=\x{0661}-\x{0662}"]]],
        ['repeated Range fields', [
            ['range', 'bytes=0-1'], ['range', 'bytes=8-9'],
        ]],
    ) {
        my ($label, $headers) = @$case;
        my $direct_case = capture_events(
            $file_app, $scope_for->('GET', $headers),
        );
        my $wrapped_case = capture_events(
            $static_app, $scope_for->('GET', $headers),
        );
        is($wrapped_case, $direct_case,
            "Static exactly preserves File handling for $label");
        is($wrapped_case->[0]{status}, 416,
            "$label retains the strict shared status");

        my $direct_head_case = capture_events(
            $file_app, $scope_for->('HEAD', $headers),
        );
        my $wrapped_head_case = capture_events(
            $static_app, $scope_for->('HEAD', $headers),
        );
        is($wrapped_head_case, $direct_head_case,
            "Static HEAD exactly preserves File handling for $label");
        is($wrapped_head_case->[0]{status}, 200,
            "$label HEAD ignores Range and retains the full status");
    }

    my $direct_head = capture_events($file_app, $scope_for->('HEAD'));
    my $wrapped_head = capture_events($static_app, $scope_for->('HEAD'));
    is($wrapped_head, $direct_head,
        'HEAD status, headers, and empty body match File exactly');

    my $direct_default = capture_events(
        $file_app, $scope_for->('GET', [], '/opaque.unknown'),
    );
    my $wrapped_default = capture_events(
        $static_app, $scope_for->('GET', [], '/opaque.unknown'),
    );
    is(event_header($direct_default->[0], 'Content-Type'),
        'application/octet-stream', 'File uses its default MIME type');
    is(event_header($wrapped_default->[0], 'Content-Type'),
        event_header($direct_default->[0], 'Content-Type'),
        'Static preserves File default MIME behavior');

    my %shared_types = (
        csv => 'text/csv',
        gz  => 'application/gzip',
        tar => 'application/x-tar',
        eot => 'application/vnd.ms-fontobject',
        otf => 'font/otf',
        ogg => 'audio/ogg',
        wav => 'audio/wav',
    );
    for my $extension (sort keys %shared_types) {
        write_test_file(
            File::Spec->catfile($root, "sample.$extension"), $extension,
        );
        my $path = "/sample.$extension";
        my $direct_type = capture_events(
            $file_app, $scope_for->('GET', [], $path),
        );
        my $wrapped_type = capture_events(
            $static_app, $scope_for->('GET', [], $path),
        );
        is(event_header($direct_type->[0], 'Content-Type'),
            $shared_types{$extension},
            "File retains the .$extension MIME mapping");
        is(event_header($wrapped_type->[0], 'Content-Type'),
            $shared_types{$extension},
            "Static retains the .$extension MIME mapping through File");
    }
};

subtest 'Static propagates File locate failures without sending a response' => sub {
    my $mw = PAGI::Middleware::Static->new(root => $test_root);
    $mw->{file} = bless {}, 'Local::StaticProbeFailure';
    my @events;
    my @calls;
    my $wrapped = $mw->wrap(sentinel_app(\@calls, 'probe passed'));
    my $scope = {
        type => 'http', method => 'GET', path => '/hello.txt', headers => [],
    };

    like(dies {
        $wrapped->(
            $scope,
            sub { return Future->done({ type => 'http.disconnect' }) },
            sub { push @events, $_[0]; return Future->done },
        )->get;
    }, qr/simulated static probe failure/,
        'locate exception propagates from the shared engine');
    is(\@events, [], 'failed locate emits no response events');
    is(\@calls, [], 'failed locate does not invoke the inner app');
};

done_testing;
