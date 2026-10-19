use strict;
use warnings;
use Test2::V0;

use lib 't/lib';
use File::Temp qw(tempfile);
use PAGI::Response qw(response);
use PAGI::Response::Stream ();
use PAGI::Response::NDJSON ();
use PAGI::Response::File ();
use PAGI::Test::Client;

# An empty body on a no-body status (1xx, 204, 304; and 205) is accepted by
# every buffered class (R1, signed off by John 2026-10-18); the unbuffered
# classes, which always have a body to deliver, keep refusing one.

sub sent {
    my ($response) = @_;
    my $res = PAGI::Test::Client->new(app => $response->to_app)->get('/');
    my %names = map { (lc($_->[0]) => $_->[1]) } @{ $res->header_pairs };
    return ($res, \%names);
}

subtest 'buffered classes accept an empty body on a no-body status' => sub {
    for my $status (100, 204, 205, 304) {
        ok(lives { PAGI::Response->new('', status => $status) }, "base class, $status");
        ok(lives { response('Text', '', status => $status) }, "Text, $status");
        ok(lives { response('HTML', '', status => $status) }, "HTML, $status");
        ok(lives { PAGI::Response->new(undef, status => $status) }, "base class with undef, $status");
    }
};

subtest 'sent with no default Content-Type and no Content-Length' => sub {
    for my $status (204, 304) {
        for my $built (
            [ 'base class' => PAGI::Response->new('', status => $status) ],
            [ 'Text'       => response('Text', '', status => $status) ],
            [ 'HTML'       => response('HTML', '', status => $status) ],
        ) {
            my ($label, $response) = @$built;
            ok(!$response->has_content_type, "$label, $status: no default Content-Type");
            my ($res, $headers) = sent($response);
            is($res->status, $status, "$label, $status: the status is sent");
            is($res->content, '', "$label, $status: no body");
            ok(!exists $headers->{'content-type'}, "$label, $status: no Content-Type sent");
            ok(!exists $headers->{'content-length'}, "$label, $status: no Content-Length sent");
        }
    }
};

subtest '205 keeps its Content-Length: 0' => sub {
    my (undef, $headers) = sent(response('Text', '', status => 205));
    is($headers->{'content-length'}, '0', 'Content-Length: 0');
};

subtest 'an explicit Content-Type on a no-body status is sent' => sub {
    for my $built (
        [ 'content_type option' => response('Text', '', status => 204, content_type => 'text/csv') ],
        [ 'headers option'      => PAGI::Response->new('', status => 204, headers => ['Content-Type' => 'image/png']) ],
        [ 'header() later'      => PAGI::Response->new('', status => 304)->header('Content-Type' => 'image/png') ],
    ) {
        my ($label, $response) = @$built;
        my (undef, $headers) = sent($response);
        ok(exists $headers->{'content-type'}, "$label: sent");
    }
    like(dies { response('Empty', content_type => 'text/plain') },
        qr/Empty response does not permit Content-Type/, 'Empty still refuses one');
};

subtest 'a non-empty body on a no-body status is still refused' => sub {
    for my $status (100, 204, 205, 304) {
        like(dies { response('Text', 'x', status => $status) },
            qr/response body is forbidden for status \Q$status\E/, "Text 'x' at construction, $status");
        like(dies { PAGI::Response->new('x')->status($status) },
            qr/response body is forbidden for status \Q$status\E/, "base 'x' via status(), $status");
        like(dies { response('JSON', undef, status => $status) },
            qr/response body is forbidden for status \Q$status\E/, "JSON undef (null), $status");
    }
};

subtest 'the unbuffered classes keep refusing a no-body status' => sub {
    my (undef, $path) = tempfile(UNLINK => 1);
    for my $status (100, 204, 304) {
        like(dies { PAGI::Response::Stream->new(sub { }, status => $status) },
            qr/response body is forbidden for status \Q$status\E/, "Stream at construction, $status");
        like(dies { PAGI::Response::Stream->new(sub { })->status($status) },
            qr/response body is forbidden for status \Q$status\E/, "Stream via status(), $status");
        like(dies { PAGI::Response::NDJSON->new(sub { }, status => $status) },
            qr/response body is forbidden for status \Q$status\E/, "NDJSON at construction, $status");
        like(dies { PAGI::Response::NDJSON->new(sub { })->status($status) },
            qr/response body is forbidden for status \Q$status\E/, "NDJSON via status(), $status");
        like(dies { PAGI::Response::File->new($path, status => $status) },
            qr/response body is forbidden for status \Q$status\E/, "File at construction, $status");
        like(dies { PAGI::Response::File->new($path)->status($status) },
            qr/response body is forbidden for status \Q$status\E/, "File via status(), $status");
    }
};

subtest 'the default Content-Type is decided at construction' => sub {
    ok(!response('Text', '', status => 204)->has_content_type,
        'built with 204: no default Content-Type');
    is(response('Text', '')->status(204)->content_type, 'text/plain; charset=utf-8',
        'built, then status(204): keeps the type written when it was built');
};

subtest 'Empty is unchanged' => sub {
    my $empty = response('Empty');
    is($empty->status, 204, '204 by default');
    ok(!$empty->has_content_type, 'no Content-Type');
    my (undef, $headers) = sent($empty);
    ok(!exists $headers->{'content-length'}, 'no Content-Length sent');
};

done_testing;
