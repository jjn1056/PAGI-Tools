#!/usr/bin/env perl
#
# A conformance harness for one spec rule:
#
#   "An intermediary MUST NOT invalidate what the head promised ... Before
#    transforming a body, or attaching metadata derived from one, an
#    intermediary MUST examine the response head for such commitments and
#    decline to act where it cannot honour them."
#       -- PAGI::Spec::Www, "Application Left a Response Incomplete"
#
# The rule is stated generally, so it is tested generally: each case below is
# a response head carrying a commitment, plus an assertion about what a
# conforming intermediary may not do to it. Every middleware that transforms
# a body or derives metadata from one is driven through every case.
#
# Adding a middleware here is one line. Adding a newly discovered commitment
# is one case, and every middleware is then checked against it.

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Middleware::ETag;
use PAGI::Middleware::GZip;
use PAGI::Middleware::ContentLength;
use PAGI::Middleware::Debug;

# Middleware that transform a body or attach metadata derived from one.
my %SUBJECT = (
    ETag          => sub { PAGI::Middleware::ETag->new },
    GZip          => sub { PAGI::Middleware::GZip->new },
    ContentLength => sub { PAGI::Middleware::ContentLength->new },
    Debug         => sub { PAGI::Middleware::Debug->new(enabled => 1) },
);

sub drive {
    my ($mw, $start, @body) = @_;
    my @sent;
    my $app = sub {
        my ($s, $r, $send) = @_;
        return (async sub {
            await $send->($start);
            for my $event (@body) { await $send->($event) }
            return;
        })->();
    };
    my $scope = { type => 'http', method => 'GET', path => '/x',
                  scheme => 'http', http_version => '1.1',
                  headers => [['accept-encoding', 'gzip']] };
    Future->wrap($mw->wrap($app)->($scope, sub { Future->done },
        sub { push @sent, $_[0]; Future->done }))->get;
    return @sent;
}

sub header_names {
    my (@sent) = @_;
    my ($start) = grep { $_->{type} eq 'http.response.start' } @sent;
    return () unless $start;
    return map { lc $_->[0] } @{ $start->{headers} || [] };
}

# --- the commitments -------------------------------------------------------

my @CASES = (
    {
        name  => 'trailers => 1 commits the server to chunked framing',
        start => { type => 'http.response.start', status => 200, trailers => 1,
                   headers => [['content-type', 'text/plain']] },
        body  => [ { type => 'http.response.body', body => 'checksum me',
                     more => 0 },
                   { type => 'http.response.trailers',
                     headers => [['digest', 'sha-256=abc']] } ],
        check => sub {
            my (@sent) = @_;
            my ($start) = grep { $_->{type} eq 'http.response.start' } @sent;
            ok($start && $start->{trailers},
                'the trailers declaration survives re-emission');
            is(scalar(grep { $_ eq 'content-length' } header_names(@sent)), 0,
                'no Content-Length is added, which would make the trailers unsendable');

            # Ordering matters as much as survival: a middleware holding the
            # head must not let the trailers event overtake it onto the wire.
            my ($start_at)    = grep { $sent[$_]{type} eq 'http.response.start' } 0..$#sent;
            my ($trailers_at) = grep { $sent[$_]{type} eq 'http.response.trailers' } 0..$#sent;
            ok(defined $trailers_at, 'the trailers event is forwarded');
            ok(defined $start_at && defined $trailers_at && $start_at < $trailers_at,
                'and it does not overtake the response start it belongs to');
        },
    },
    {
        name  => 'a 206 body is a range, not the representation',
        start => { type => 'http.response.start', status => 206,
                   headers => [['content-type', 'text/plain'],
                               ['content-range', 'bytes 4-11/55']] },
        # Large enough to clear GZip's min_size. With a short body GZip
        # declines for an unrelated reason and the cell passes vacuously.
        body  => [ { type => 'http.response.body', body => ('range bytes ' x 200),
                     more => 0 } ],
        check => sub {
            my (@sent) = @_;
            my @names = header_names(@sent);
            is(scalar(grep { $_ eq 'etag' } @names), 0,
                'no validator is derived from a partial body');
            is(scalar(grep { $_ eq 'content-encoding' } @names), 0,
                'no encoding is applied to a range whose bounds describe the identity representation');
        },
    },
);

for my $case (@CASES) {
    subtest $case->{name} => sub {
        for my $name (sort keys %SUBJECT) {
            subtest $name => sub {
                my @sent = drive($SUBJECT{$name}->(), $case->{start},
                                 @{ $case->{body} });
                $case->{check}->(@sent);
            };
        }
    };
}

done_testing;
