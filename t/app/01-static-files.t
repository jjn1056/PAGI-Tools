#!/usr/bin/env perl

use strict;
use warnings;
use experimental 'signatures';
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use lib 'lib';

use PAGI::App::File;
use PAGI::App::Directory;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# Create temp directory with test files
my $tmpdir = tempdir(CLEANUP => 1);
make_path("$tmpdir/subdir");

# Create test files
open my $fh, '>', "$tmpdir/test.txt" or die "Cannot create test file: $!";
print $fh "Hello, World!";
close $fh;

open $fh, '>', "$tmpdir/test.html" or die "Cannot create test file: $!";
print $fh "<html><body>Test</body></html>";
close $fh;

open $fh, '>', "$tmpdir/subdir/nested.txt" or die "Cannot create nested file: $!";
print $fh "Nested content";
close $fh;

# =============================================================================
# Test: PAGI::App::File
# =============================================================================

subtest 'App::File serves static files' => sub {

    subtest 'serves existing file' => sub {
        my $app = PAGI::App::File->new(root => $tmpdir)->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/test.txt' },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'returns 200 status';
        ok((grep { $_->[0] eq 'content-type' && $_->[1] =~ /text\/plain/ } @{$sent[0]{headers}}),
            'has correct content-type');
        is $sent[1]{body}, 'Hello, World!', 'returns file content';
    };

    subtest 'returns 404 for missing file' => sub {
        my $app = PAGI::App::File->new(root => $tmpdir)->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/missing.txt' },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { push @sent, $event },
            );
        });

        is $sent[0]{status}, 404, 'returns 404 for missing file';
    };

    subtest 'serves nested files' => sub {
        my $app = PAGI::App::File->new(root => $tmpdir)->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/subdir/nested.txt' },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'serves nested file';
        is $sent[1]{body}, 'Nested content', 'correct nested content';
    };

    subtest 'prevents path traversal' => sub {
        my $app = PAGI::App::File->new(root => $tmpdir)->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/../../../etc/passwd' },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { push @sent, $event },
            );
        });

        isnt $sent[0]{status}, 200, 'blocks path traversal';
    };

    subtest 'sets ETag header' => sub {
        my $app = PAGI::App::File->new(root => $tmpdir)->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/test.txt' },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { push @sent, $event },
            );
        });

        ok((grep { $_->[0] eq 'etag' } @{$sent[0]{headers}}), 'ETag header present');
    };

    subtest 'conditional GET with If-None-Match' => sub {
        my $app = PAGI::App::File->new(root => $tmpdir)->to_app;

        # First request to get ETag
        my @sent1;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/test.txt', headers => [] },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { push @sent1, $event },
            );
        });

        my ($etag) = map { $_->[1] } grep { $_->[0] eq 'etag' } @{$sent1[0]{headers}};

        # Second request with If-None-Match
        my @sent2;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/test.txt',
                  headers => [['if-none-match', $etag]] },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { push @sent2, $event },
            );
        });

        is $sent2[0]{status}, 304, 'returns 304 Not Modified';
    };
};

# =============================================================================
# Test: PAGI::App::Directory
# =============================================================================

subtest 'App::Directory serves directory listings' => sub {

    subtest 'serves file like App::File' => sub {
        my $app = PAGI::App::Directory->new(root => $tmpdir)->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/test.txt' },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'serves file';
        is $sent[1]{body}, 'Hello, World!', 'correct content';
    };

    subtest 'lists directory as HTML' => sub {
        my $app = PAGI::App::Directory->new(root => $tmpdir)->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/' },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'returns 200';
        ok((grep { $_->[0] eq 'content-type' && $_->[1] =~ /text\/html/ } @{$sent[0]{headers}}),
            'content-type is HTML');
        like $sent[1]{body}, qr/test\.txt/, 'listing includes test.txt';
        like $sent[1]{body}, qr/subdir/, 'listing includes subdir';
    };

    subtest 'lists directory as JSON when Accept: application/json' => sub {
        my $app = PAGI::App::Directory->new(root => $tmpdir)->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', method => 'GET', path => '/',
                  headers => [['accept', 'application/json']] },
                async sub { { type => 'http.disconnect' } },
                async sub ($event) { push @sent, $event },
            );
        });

        ok((grep { $_->[0] eq 'content-type' && $_->[1] =~ /application\/json/ } @{$sent[0]{headers}}),
            'content-type is JSON');
        like $sent[1]{body}, qr/"name"/, 'JSON output has name field';
    };
};

done_testing;
