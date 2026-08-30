use strict;
use warnings;

use Test2::V0;
use Future;
use Future::AsyncAwait;
use PAGI::Utils qw(as_app invoke_app to_app);

{
    package Local::CountedApp;
    our $TO_APP_CALLS = 0;
    sub new { return bless {}, $_[0] }
    sub to_app {
        ++$TO_APP_CALLS;
        return $_[0]->{app};
    }
}

my $scope = { type => 'http', path => '/application-values' };
my $receive = async sub { return { type => 'http.disconnect' } };
my $send = async sub { return };

subtest 'as_app puts a native CODE in an object application position' => sub {
    my $native = async sub { return 'native result' };

    my $component = as_app($native);

    isa_ok($component, ['PAGI::Utils::_App'],
        'as_app returns its adapter object');
    isnt($component, $native, 'as_app creates a distinct wrapper identity');
    is(to_app($component), $native, 'as_app exposes the exact native app');
};

subtest 'invoke_app preserves the exact application triplet' => sub {
    my $seen;
    my $native = async sub {
        $seen = [@_];
        return;
    };
    my $component = as_app($native);

    invoke_app($component, $scope, $receive, $send)->get;

    is($seen, [$scope, $receive, $send], 'invoke_app preserves the triplet');
};

subtest 'invoke_app normalizes an object once and awaits immediate completion' => sub {
    my $calls = 0;
    my $object = Local::CountedApp->new;
    $object->{app} = sub {
        ++$calls;
        return 'immediate result';
    };

    my $result = invoke_app($object, $scope, $receive, $send)->get;

    is($result, 'immediate result', 'immediate application result is awaited');
    is($calls, 1, 'the normalized app is invoked once');
    is($Local::CountedApp::TO_APP_CALLS, 1, 'object to_app is called once');
};

subtest 'invoke_app awaits a Future result' => sub {
    my $returned = Future->new;
    my $app = sub { return $returned };
    my $invocation = invoke_app($app, $scope, $receive, $send);

    ok(!$invocation->is_ready, 'invocation remains pending with its returned Future');
    $returned->done('future result');

    is($invocation->get, 'future result', 'Future result is awaited');
};

subtest 'invoke_app propagates application failure unchanged' => sub {
    my $failure = 'application returned failure';
    my $app = sub { return Future->fail($failure) };

    like(dies { invoke_app($app, $scope, $receive, $send)->get },
        qr/\Q$failure\E/, 'failed application Future propagates');
};

done_testing;
