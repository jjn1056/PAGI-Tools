use strict;
use warnings;

use Test2::V0;
use FindBin;
use lib "$FindBin::Bin/lib";

use PAGI::Test::Client;
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

done_testing;
