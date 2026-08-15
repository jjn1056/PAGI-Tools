#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::Middleware::ErrorHandler;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: ErrorHandler middleware catches exceptions
# =============================================================================

subtest 'ErrorHandler catches exceptions and returns 500' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new;

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        die "Something went wrong!";
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/' },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is scalar(@sent), 2, 'two events sent (start + body)';
    is $sent[0]{type}, 'http.response.start', 'first event is response start';
    is $sent[0]{status}, 500, 'status is 500';

    # Check content-type header
    my $ct;
    for my $h (@{$sent[0]{headers}}) {
        if (lc($h->[0]) eq 'content-type') {
            $ct = $h->[1];
            last;
        }
    }
    like $ct, qr/text\/html/, 'content-type is text/html';
    ok scalar(grep {
        lc($_->[0]) eq 'cache-control' && $_->[1] eq 'no-store'
    } @{$sent[0]{headers}}), 'built-in HTML response is not cacheable';
    like $sent[1]{body}, qr/500\s+Internal Server Error/,
        'body contains the Pages status and title';
};

subtest 'ErrorHandler shows exception detail in development mode' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new(development => 1);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        die "Detailed error message";
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/' },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    like $sent[1]{body}, qr/Detailed error message/, 'error message shown in dev mode';
    like $sent[1]{body}, qr/500\s+Internal Server Error/,
        'development response retains the status semantics';
};

subtest 'ErrorHandler hides details in production mode' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new(development => 0);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        die "Secret internal error details";
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/' },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    unlike $sent[1]{body}, qr/Secret internal error details/, 'error details hidden in production';
    like $sent[1]{body}, qr/Internal Server Error/, 'generic message shown';
};

subtest 'ErrorHandler calls on_error callback' => sub {
    my @errors;
    my $mw = PAGI::Middleware::ErrorHandler->new(
        on_error => sub  {
        my ($error) = @_; push @errors, $error },
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        die "Test error for callback";
    };

    my $wrapped = $mw->wrap($app);

    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/' },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; },
        );
    });

    is scalar(@errors), 1, 'on_error called once';
    like $errors[0], qr/Test error for callback/, 'error passed to callback';
};

subtest 'ErrorHandler negotiates problem JSON' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new(development => 1);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        die "JSON error";
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type => 'http', path => '/',
                headers => [['Accept' => 'application/problem+json']],
            },
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
    is $ct, 'application/problem+json', 'content-type is problem JSON';
    ok scalar(grep {
        lc($_->[0]) eq 'cache-control' && $_->[1] eq 'no-store'
    } @{$sent[0]{headers}}), 'built-in JSON response is not cacheable';

    require JSON::MaybeXS;
    my $data = JSON::MaybeXS::decode_json($sent[1]{body});
    is $data->{status}, 500, 'problem JSON contains status';
    is $data->{title}, 'Internal Server Error', 'problem JSON contains title';
    like $data->{detail}, qr/JSON error/, 'problem JSON contains development detail';
};

subtest 'ErrorHandler negotiates plain text' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new;

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        die "Plain text error";
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            {
                type => 'http', path => '/',
                headers => [['Accept' => 'text/plain']],
            },
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
    like $ct, qr/text\/plain/, 'content-type is plain text';
    ok scalar(grep {
        lc($_->[0]) eq 'cache-control' && $_->[1] eq 'no-store'
    } @{$sent[0]{headers}}), 'built-in plain response is not cacheable';
    like $sent[1]{body}, qr/500\s+Internal Server Error/,
        'plain text body contains Pages status semantics';
};

subtest 'ErrorHandler rejects the removed content_type option' => sub {
    like dies {
        PAGI::Middleware::ErrorHandler->new(content_type => 'text/plain')
    }, qr/unknown ErrorHandler option 'content_type'/,
        'fixed representations use a custom handler';
};

subtest 'ErrorHandler respects exception status_code method' => sub {
    package TestException {
        sub new { bless { status => $_[1] }, $_[0] }
        sub status_code { $_[0]->{status} }
    }

    my $mw = PAGI::Middleware::ErrorHandler->new;

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        die TestException->new(404);
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/' },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{status}, 404, 'status from exception status_code method';
    like $sent[1]{body}, qr/404\s+Not Found/, 'body reflects Pages status semantics';
};

subtest 'ErrorHandler passes through successful responses' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new;

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'Success!',
            more => 0,
        });
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/' },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    is scalar(@sent), 2, 'two events sent';
    is $sent[0]{status}, 200, 'status is 200';
    is $sent[1]{body}, 'Success!', 'body is correct';
};

subtest 'ErrorHandler skips non-HTTP requests' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new;

    my $app_called = 0;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $app_called = 1;
        die "WebSocket error";
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    my $future = $wrapped->(
        { type => 'websocket', path => '/' },
        async sub { { type => 'websocket.disconnect' } },
        async sub  {
        my ($event) = @_; push @sent, $event },
    );

    # The future should fail (not be caught by middleware)
    $loop->await($future->else(sub { Future->done }));

    ok $app_called, 'app was called';
    ok $future->is_failed, 'future failed (error propagated)';
    like $future->failure, qr/WebSocket error/, 'original error preserved';
};

subtest 'ErrorHandler escapes HTML in error messages' => sub {
    my $mw = PAGI::Middleware::ErrorHandler->new(development => 1);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        die "<script>alert('xss')</script>";
    };

    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/' },
            async sub { { type => 'http.disconnect' } },
            async sub  {
        my ($event) = @_; push @sent, $event },
        );
    });

    unlike $sent[1]{body}, qr/<script>/, 'script tag escaped';
    like $sent[1]{body}, qr/&lt;script&gt;/, 'HTML entities used';
};

done_testing;
