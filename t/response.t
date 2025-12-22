use strict;
use warnings;
use v5.32;
use Test2::V0;
use Future;

use PAGI::Response;

subtest 'constructor' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);
    isa_ok $res, 'PAGI::Response';
};

subtest 'constructor requires send' => sub {
    like dies { PAGI::Response->new() }, qr/send.*required/i, 'dies without send';
};

subtest 'constructor requires coderef' => sub {
    like dies { PAGI::Response->new("not a coderef") },
         qr/coderef/i, 'dies with non-coderef';
};

subtest 'status method' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->status(404);
    is $ret, $res, 'status returns self for chaining';
};

subtest 'header method' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->header('X-Custom' => 'value');
    is $ret, $res, 'header returns self for chaining';
};

subtest 'content_type method' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->content_type('application/xml');
    is $ret, $res, 'content_type returns self for chaining';
};

subtest 'chaining multiple methods' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);

    my $ret = $res->status(201)->header('X-Foo' => 'bar')->content_type('text/plain');
    is $ret, $res, 'chaining works';
};

subtest 'status sets internal state' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);
    $res->status(404);
    is $res->{_status}, 404, 'status code set correctly';
};

subtest 'header adds to headers array' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);
    $res->header('X-Custom' => 'value1');
    $res->header('X-Other' => 'value2');
    is scalar(@{$res->{_headers}}), 2, 'two headers added';
};

subtest 'content_type replaces existing' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);
    $res->header('Content-Type' => 'text/html');
    $res->content_type('text/plain');
    my @ct = grep { lc($_->[0]) eq 'content-type' } @{$res->{_headers}};
    is scalar(@ct), 1, 'only one content-type header';
    is $ct[0][1], 'text/plain', 'content-type replaced';
};

subtest 'status rejects invalid codes' => sub {
    my $send = sub { Future->done };
    my $res = PAGI::Response->new($send);
    like dies { $res->status("not a number") }, qr/number/i, 'rejects non-number';
    like dies { $res->status(99) }, qr/100-599/i, 'rejects < 100';
    like dies { $res->status(600) }, qr/100-599/i, 'rejects > 599';
};

done_testing;
