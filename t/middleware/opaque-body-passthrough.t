#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use Future::AsyncAwait;
use File::Temp qw(tempfile);

use lib 'lib';

use PAGI::Middleware::ETag;
use PAGI::Middleware::GZip;
use PAGI::Middleware::ContentLength;
use PAGI::Response::File;
use PAGI::Test::Client;

# C2: ETag/GZip/ContentLength must not destroy or mis-frame opaque
# (file/fh) response bodies. Each is composed over (a) a
# PAGI::Response::File app and (b) a raw fh-body app, and must
# deliver the file byte-identical, with the correct status, and without
# adding its own transform header.

my $file_content = "Opaque body pass-through fixture.\n" x 50;

my ($fh, $path) = tempfile(UNLINK => 1);
binmode $fh;
print {$fh} $file_content;
close $fh;

# (a) An app built from PAGI::Response::File -- sets its own
# content-type/content-length/content-disposition and emits a body event
# with a `file` key (no `body`, no `more`).
sub file_response_app {
    return PAGI::Response::File->new($path)->to_app;
}

my $file_response_etag = PAGI::Test::Client->new(
    app => file_response_app(),
)->get('/')->header('etag');

# (b) A raw app that emits an opaque `fh` body event directly, without any
# of File's header bookkeeping.
sub fh_app {
    return async sub {
        my ($scope, $receive, $send) = @_;
        open my $body_fh, '<:raw', $path or die "Cannot open $path: $!";
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            fh   => $body_fh,
        });
    };
}

my %scenarios = (
    'PAGI::Response::File' => \&file_response_app,
    'fh body event'             => \&fh_app,
);

my %middleware = (
    ETag          => sub { PAGI::Middleware::ETag->new },
    GZip          => sub { PAGI::Middleware::GZip->new(min_size => 10) },
    ContentLength => sub { PAGI::Middleware::ContentLength->new },
);

for my $mw_name (sort keys %middleware) {
    for my $scenario_name (sort keys %scenarios) {
        subtest "$mw_name over $scenario_name: opaque body passes through untouched" => sub {
            my $mw = $middleware{$mw_name}->();
            my $app = $scenarios{$scenario_name}->();
            my $wrapped = $mw->wrap($app);

            my $client = PAGI::Test::Client->new(app => $wrapped);
            # GZip only engages its interception logic when the client
            # negotiates gzip -- exercise that path deliberately.
            my $res = $client->get('/', headers => [['Accept-Encoding', 'gzip']]);

            is $res->status, 200, 'status is 200';
            is $res->content, $file_content, 'body delivered byte-identical to the file';

            if ($mw_name eq 'ETag') {
                if ($scenario_name eq 'PAGI::Response::File') {
                    is $res->header('etag'), $file_response_etag,
                        "the app's own File ETag is left untouched";
                }
                else {
                    ok !defined($res->header('etag')), 'no ETag header was added';
                }
            }
            elsif ($mw_name eq 'GZip') {
                ok !defined($res->header('content-encoding')), 'no Content-Encoding header was added';
            }
            elsif ($mw_name eq 'ContentLength') {
                if ($scenario_name eq 'fh body event') {
                    ok !defined($res->header('content-length')),
                        'no Content-Length synthesized for an opaque body without one already';
                }
                else {
                    # File sets its own accurate Content-Length; the
                    # middleware must leave it alone, not recompute it.
                    is $res->header('content-length'), length($file_content),
                        "the app's own Content-Length is left untouched";
                }
            }
        };
    }
}

# Mixing inline chunks with an opaque event is a protocol fault: a response's
# body is inline events or one opaque event, never both, and the server fails
# that send (PAGI::Spec::Www, "Payload kinds do not mix within a response").
#
# Middleware sit inside the server's send, so they observe the illegal event
# before the server rejects it. What matters is that they FORWARD it: a
# middleware that swallowed it would deny the server the event it needs to
# raise the error, turning a loud protocol fault into a silent truncation.
# What a middleware does to the inline bytes around it is its own business --
# GZip legitimately compresses them, having declared an encoding it cannot
# retract.
subtest 'an illegal opaque event still reaches the server, so it can be rejected' => sub {
    for my $mw_name (sort keys %middleware) {
        subtest $mw_name => sub {
            my $mw = $middleware{$mw_name}->();

            my $app = async sub {
                my ($scope, $receive, $send) = @_;
                open my $body_fh, '<:raw', $path or die "Cannot open $path: $!";
                await $send->({
                    type    => 'http.response.start',
                    status  => 200,
                    headers => [['content-type', 'text/plain']],
                });
                await $send->({
                    type => 'http.response.body',
                    body => 'leading chunk;',
                    more => 1,
                });
                await $send->({
                    type => 'http.response.body',
                    fh   => $body_fh,
                });
            };

            my $wrapped = $mw->wrap($app);

            my @sent;
            my $loop_receive = async sub { { type => 'http.disconnect' } };
            my $send = async sub { my ($event) = @_; push @sent, $event };

            require IO::Async::Loop;
            my $loop = IO::Async::Loop->new;
            $loop->await($wrapped->(
                { type => 'http', path => '/', method => 'GET', headers => [['Accept-Encoding', 'gzip']] },
                $loop_receive,
                $send,
            ));

            my @body_events = grep { $_->{type} eq 'http.response.body' } @sent;
            my ($start)     = grep { $_->{type} eq 'http.response.start' } @sent;
            is scalar(@body_events), 2, 'two body events sent';

            # Check the inline bytes, not merely that they are inline. A
            # middleware that declared an encoding must have applied it; one
            # that declared none must have left the bytes alone.
            my $encoded = grep { lc($_->[0]) eq 'content-encoding'
                                 && $_->[1] eq 'gzip' } @{ $start->{headers} || [] };
            my $first = $body_events[0]{body};
            if ($encoded) {
                # A streaming chunk is a Z_SYNC_FLUSH fragment of the deflate
                # stream, not a standalone gzip member, so it cannot be
                # decoded on its own -- especially here, where the illegal
                # opaque event means the stream never reaches Z_FINISH. What
                # is checkable is that the declared encoding was actually
                # applied: gzip framing present, application bytes absent.
                is substr($first, 0, 2), "\x1f\x8b",
                    'the inline chunk carries gzip framing, as the head declared';
                isnt $first, 'leading chunk;',
                    'and is not the raw application bytes under a gzip header';
            }
            else {
                is $first, 'leading chunk;', 'the inline chunk is forwarded unchanged';
            }

            ok exists $body_events[1]{fh},
                'the opaque event is forwarded rather than swallowed, so the server can reject it';
        };
    }
};

done_testing;
