use strict;
use warnings;

use Test2::V0;
use Future;
use Future::AsyncAwait;
use PAGI::Utils qw(as_app_object invoke_app request_response to_app);

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

subtest 'as_app_object puts a native CODE in an app-object position' => sub {
    my $native = async sub { return 'native result' };

    my $component = as_app_object($native);

    isa_ok($component, ['PAGI::Utils::AppObject'],
        'as_app_object returns the named app-object adapter');
    isnt($component, $native,
        'as_app_object creates a distinct wrapper identity');
    is(to_app($component), $native,
        'as_app_object exposes the exact native app');
};

subtest 'as_app_object requires exactly one application value' => sub {
    my $native = sub { return };

    like(dies { as_app_object() },
        qr/as_app_object\(\) requires exactly one native coderef or app object/,
        'as_app_object rejects no argument');
    like(dies { as_app_object($native, 'extra') },
        qr/as_app_object\(\) requires exactly one native coderef or app object/,
        'as_app_object rejects extra arguments');

    for my $case (
        [undef, 'undefined'],
        ['not a coderef', 'a scalar'],
        [{}, 'a hash reference'],
    ) {
        like(dies { as_app_object($case->[0]) },
            qr/as_app_object\(\) requires exactly one native coderef or app object/,
            "as_app_object rejects $case->[1]");
    }
};

subtest 'as_app_object returns an existing app object unchanged with a warning' => sub {
    my $native = sub { return 'already an app object' };
    my $object = Local::CountedApp->new;
    $object->{app} = $native;
    my $warning = '';

    my $returned;
    {
        local $SIG{__WARN__} = sub { $warning .= $_[0] };
        $returned = as_app_object($object);
    }

    is($returned, $object, 'the exact existing app object is returned');
    like($warning,
        qr/as_app_object\(\) received an app object; returning it unchanged/,
        'the redundant conversion is reported');
    is($Local::CountedApp::TO_APP_CALLS, 0,
        'the defensive pass-through does not compile the object');
};

subtest 'request_response is opt-in and included in the all export bundle' => sub {
    my $utility = 'PAGI::Utils';
    ok($utility->can('request_response'),
        'request_response is available as an explicit utility');

    {
        package Local::AllRequestResponseImport;
        use PAGI::Utils qw(:all);
    }

    ok(Local::AllRequestResponseImport->can('request_response'),
        'request_response is included in :all');
};

subtest 'as_app_object keeps its wrapped CODE opaque to caller mutation' => sub {
    my $native = sub { return 'native' };
    my $replacement = sub { return 'replacement' };
    my $component = as_app_object($native);

    my $mutation_succeeded = eval {
        $component->{app} = $replacement;
        1;
    };

    ok(!$mutation_succeeded, 'callers cannot replace the wrapped CODE');
    is(to_app($component), $native,
        'to_app retains the exact originally wrapped CODE');
};

subtest 'invoke_app preserves the exact application triplet' => sub {
    my $seen;
    my $native = async sub {
        $seen = [@_];
        return;
    };
    my $component = as_app_object($native);

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
