use strict;
use warnings;

# Future::IO is only recommended: hide it, so this file runs as an install
# without it does.
BEGIN { unshift @INC, sub { die "Future::IO hidden by this test\n" if $_[1] =~ m{^Future/IO[/.]}; return } }

use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';
use PAGI::Test::Client;

ok(!eval { require Future::IO; 1 }, 'Future::IO cannot be loaded');

subtest 'an app waiting on its own event loop completes without Future::IO' => sub {
    my $loop = IO::Async::Loop->new;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $loop->delay_future(after => 0.1);
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({ type => 'http.response.body', body => 'ready', more => 0 });
    };
    is(PAGI::Test::Client->new(app => $app)->get('/')->content, 'ready',
        "the app's own loop is driven");
};

done_testing;
