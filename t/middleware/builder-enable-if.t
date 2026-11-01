use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Middleware::Builder;
use PAGI::Response qw(response);
use PAGI::Test::Client;

{
    package Local::Counting;
    use parent 'PAGI::Middleware';
    use Future::AsyncAwait;

    our $BUILT = 0;
    our @SEEN;

    sub new { $BUILT++; return shift->SUPER::new(@_) }

    sub wrap {
        my ($self, $app) = @_;
        return async sub {
            push @SEEN, ++$self->{seen};
            await $app->(@_);
        };
    }
}

my $inner = response('Text', 'ok');

sub requests {
    my ($app, $count) = @_;
    my $client = PAGI::Test::Client->new(app => $app);
    return map { $client->get('/x')->status } 1 .. $count;
}

subtest 'enable_if builds a named middleware once and keeps it across requests' => sub {
    for my $case (
        [dsl    => sub { builder { enable_if { 1 } '+Local::Counting'; $inner } }],
        [object => sub {
            my $builder = PAGI::Middleware::Builder->new;
            $builder->add_middleware_if(sub { 1 }, '+Local::Counting');
            $builder->to_app($inner);
        }],
    ) {
        my ($form, $build) = @$case;
        local $Local::Counting::BUILT = 0;
        local @Local::Counting::SEEN;
        my $app = $build->();
        is $Local::Counting::BUILT, 1, "$form: built when the app is built";
        requests($app, 3);
        is $Local::Counting::BUILT, 1, "$form: not rebuilt per request";
        is \@Local::Counting::SEEN, [1, 2, 3], "$form: one instance sees every request";
    }
};

subtest 'a rate limit under enable_if limits' => sub {
    my $app = builder {
        enable_if { 1 } 'RateLimit', requests_per_second => 1, burst => 1;
        $inner;
    };
    is [requests($app, 2)], [200, 429], 'the second request is refused';
};

subtest 'a request the condition skips goes straight to the app' => sub {
    local $Local::Counting::BUILT = 0;
    local @Local::Counting::SEEN;
    my $app = builder { enable_if { 0 } '+Local::Counting'; $inner };
    is [requests($app, 2)], [200, 200], 'answered by the app';
    is \@Local::Counting::SEEN, [], 'the middleware saw nothing';
};

subtest 'bad middleware options fail when the app is built' => sub {
    like dies { builder { enable_if { 0 } 'RateLimit', limit => 1; $inner } },
        qr/RateLimit has unknown option 'limit'/,
        'an option error surfaces at build time, not on a matching request';
};

done_testing;
