use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);

use PAGI::CSRF qw(csrf);
use PAGI::Request;
use PAGI::WebSocket;
use PAGI::SSE;

{
    package Local::CSRF::NoDefault;
    PAGI::CSRF->import;
}

{
    package Local::CSRF::Named;
    PAGI::CSRF->import('csrf');
}

{
    package Local::CSRF::All;
    PAGI::CSRF->import(':ALL');
}

ok(!Local::CSRF::NoDefault->can('csrf'), 'csrf is not exported by default');
ok(Local::CSRF::Named->can('csrf'), 'csrf is available as a named export');
ok(Local::CSRF::All->can('csrf'), 'uppercase :ALL exports csrf');

my $lowercase_tag_error;
{
    local $SIG{__WARN__} = sub { };
    $lowercase_tag_error = dies { PAGI::CSRF->import(':all') };
}
like($lowercase_tag_error, qr/"?:all"? is not defined|Can't continue/i,
    'lowercase :all is not an export tag');

subtest 'scope and direct protocol sources expose the exact token' => sub {
    my $scope = {
        type       => 'http',
        method     => 'GET',
        headers    => [],
        csrf_token => 'scope-token',
    };
    my $request = PAGI::Request->new($scope, sub { });

    isa_ok(csrf($scope), ['PAGI::CSRF'], 'raw scope constructs a facade');
    is(csrf($scope)->token, 'scope-token', 'raw scope returns its token exactly');
    is(PAGI::CSRF->new($request)->token, 'scope-token',
        'strict Request source returns its scope token');

    for my $case (
        ['WebSocket', 'websocket', sub { PAGI::WebSocket->new($_[0], sub {}, sub {}) }],
        ['SSE', 'sse', sub { PAGI::SSE->new($_[0], sub {}, sub {}) }],
    ) {
        my ($name, $type, $build) = @{$case};
        my $source = $build->({ type => $type, headers => [], csrf_token => 'scope-token' });
        is(csrf($source)->token, 'scope-token', "$name source returns its scope token");
    }
};

subtest 'provider validation rejects missing and malformed tokens' => sub {
    like(dies { csrf({ type => 'http' }) }, qr/PAGI::CSRF.*csrf_token/i,
        'missing provider is rejected');
    like(dies { csrf({ type => 'http', csrf_token => undef }) },
        qr/PAGI::CSRF.*csrf_token/i, 'undefined provider is rejected');
    like(dies { csrf({ type => 'http', csrf_token => '' }) },
        qr/PAGI::CSRF.*csrf_token/i, 'empty provider is rejected');

    my $marker = 'TOKEN-MUST-NOT-LEAK';
    my $error = dies {
        csrf({ type => 'http', csrf_token => [$marker] });
    };
    like($error, qr/PAGI::CSRF.*csrf_token/i, 'reference provider is rejected');
    unlike($error, qr/\Q$marker\E/, 'provider diagnostics do not expose token text');
};

subtest 'verification accepts only matching nonempty submitted values' => sub {
    my $guard = csrf({ type => 'http', csrf_token => 'expected-token' });

    ok($guard->verify('expected-token'), 'matching submitted token verifies');
    ok(!$guard->verify('different-token'), 'mismatching submitted token fails');
    ok(!$guard->verify(undef), 'missing submitted token fails');
    ok(!$guard->verify(''), 'empty submitted token fails');
};

subtest 'facades are independent and read the backing token at operation time' => sub {
    my $scope = { type => 'http', csrf_token => 'first-token' };
    my @keys_before = sort keys %{$scope};
    my $first = csrf($scope);
    my $second = csrf($scope);

    isnt(refaddr($first), refaddr($second), 'each factory call returns a new facade');
    $scope->{csrf_token} = 'second-token';
    is($first->token, 'second-token', 'first facade reads the current backing token');
    ok($second->verify('second-token'), 'second facade verifies the current backing token');
    is([sort keys %{$scope}], \@keys_before, 'facade construction adds no scope cache key');
};

subtest 'constructor, factory, and methods enforce strict arity' => sub {
    my $scope = { type => 'http', csrf_token => 'arity-token' };
    my $guard = csrf($scope);

    like(dies { PAGI::CSRF->new() }, qr/exactly one.*scope/i,
        'constructor rejects a missing source');
    like(dies { PAGI::CSRF->new($scope, $scope) }, qr/exactly one.*scope/i,
        'constructor rejects multiple sources');
    like(dies { csrf() }, qr/exactly one.*scope/i,
        'factory rejects a missing source');
    like(dies { csrf($scope, $scope) }, qr/exactly one.*scope/i,
        'factory rejects multiple sources');
    like(dies { $guard->token('extra') }, qr/token.*no arguments/i,
        'token rejects arguments');
    like(dies { $guard->verify() }, qr/verify.*exactly one/i,
        'verify rejects a missing submitted argument');
    like(dies { $guard->verify('one', 'two') }, qr/verify.*exactly one/i,
        'verify rejects multiple submitted arguments');
};

done_testing;
