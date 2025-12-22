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

done_testing;
