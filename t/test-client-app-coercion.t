use strict;
use warnings;

use Test2::V0;
use FindBin;
use lib "$FindBin::Bin/lib";

use PAGI::Test::Client;
use PAGI::Response::Text;
use TestApps::Component;

subtest 'client coerces component objects' => sub {
    my $client = PAGI::Test::Client->new(
        app => TestApps::Component->new(body => 'from-component'),
    );
    my $res = $client->get('/');
    is $res->status, 200, 'request served';
    is $res->content, 'from-component', 'component compiled by client';
};

subtest 'client rejects package strings in its native app position' => sub {
    like(
        dies { PAGI::Test::Client->new(app => 'TestApps::Component') },
        qr/application must be a coderef or instantiated object with to_app/,
        'package string croaks with explicit construction guidance',
    );
};

subtest 'client executes a terminal Response and returns captured wire data' => sub {
    my $client = PAGI::Test::Client->new(
        app => PAGI::Response::Text->new(
            'from-response',
            status  => 201,
        ),
    );

    my $res = $client->get('/');

    isa_ok $res, ['PAGI::Test::Response'],
        'client returns its captured-wire response type';
    ok !$res->isa('PAGI::Response'),
        'test response is not a production Response';
    is $res->status, 201, 'wire status decoded';
    is $res->content, 'from-response', 'wire body decoded';
};

subtest 'client preserves repeated headers emitted by a terminal Response' => sub {
    my $client = PAGI::Test::Client->new(
        app => PAGI::Response::Text->new(
            'headers',
            headers => [
                'X-Wire' => 'first',
                'X-Wire' => 'second',
            ],
        ),
    );

    my $res = $client->get('/');

    is $res->header_all('x-wire'), ['first', 'second'],
        'repeated wire headers remain observable';
};

done_testing;
