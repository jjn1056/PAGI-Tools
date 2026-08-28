use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Utils::Scope ();

{
    package Local::Bearer;
    sub new {
        my ($class, $scope) = @_;
        return bless { scope => $scope }, $class;
    }
    sub scope { return $_[0]{scope} }
}

{
    package Local::BadScope;
    sub new { return bless {}, $_[0] }
    sub scope { return [] }
}

{
    package Local::DiesScope;
    sub new { return bless {}, $_[0] }
    sub scope { die 'source scope exploded' }
}

{
    package Local::CachedObject;
    sub new { return bless { scope => $_[1] }, $_[0] }
    sub scope { return $_[0]{scope} }
}

{
    package Local::CachedObjectWithDyingScope;
    sub new { return bless {}, $_[0] }
    sub scope { die 'cached scope exploded' }
}

my $scope = { type => 'http' };
is(PAGI::Utils::Scope::scope_from_source('Widget', $scope), exact_ref($scope),
    'an unblessed scope is returned by identity');
is(PAGI::Utils::Scope::scope_from_source('Widget', Local::Bearer->new($scope)), exact_ref($scope),
    'a scope-bearing object resolves to its exact scope');
ok(PAGI::Utils::Scope::is_scope_source($scope), 'scope is a source candidate');
ok(PAGI::Utils::Scope::is_scope_source(Local::Bearer->new($scope)), 'bearer is a candidate');
ok(!PAGI::Utils::Scope::is_scope_source('Local::Bearer'), 'package string is not a source');
like(dies { PAGI::Utils::Scope::scope_from_source('Widget') }, qr/Widget.*exactly one.*scope/i);
like(dies { PAGI::Utils::Scope::scope_from_source('Widget', $scope, 1) }, qr/Widget.*exactly one/i);
like(dies { PAGI::Utils::Scope::scope_from_source('Widget', []) },
    qr/Widget.*unblessed scope hashref.*scope\(\)/i);
like(dies { PAGI::Utils::Scope::scope_from_source('Widget', Local::BadScope->new) },
    qr/Widget.*unblessed scope hashref/i);
like(dies { PAGI::Utils::Scope::scope_from_source('Widget', Local::DiesScope->new) },
    qr/source scope exploded/, 'source scope exceptions are preserved');

subtest '_compatible_cached_scope_object reuses only an exact-class object bound to this scope' => sub {
    my $scope = { type => 'websocket' };
    my $other_scope = { type => 'websocket' };
    my @cases = (
        [ absent => undef, undef ],
        [ valid => Local::CachedObject->new($scope), 'Local::CachedObject' ],
        [ 'wrong class' => Local::BadScope->new, 'Local::CachedObject' ],
        [ 'throwing scope' => Local::CachedObjectWithDyingScope->new,
            'Local::CachedObject' ],
        [ 'other scope' => Local::CachedObject->new($other_scope),
            'Local::CachedObject' ],
    );

    for my $case (@cases) {
        my ($label, $cached, $expected_class) = @$case;
        my $key = 'cached.object';
        $scope->{$key} = $cached if defined $cached;

        my $got = PAGI::Utils::Scope::_compatible_cached_scope_object(
            $scope, $key, $expected_class // 'Local::CachedObject',
        );

        if ($label eq 'valid') {
            is(refaddr($got), refaddr($cached),
                'the valid exact object is returned unchanged');
            ok(exists $scope->{$key}, 'the valid cache entry remains');
        }
        else {
            is($got, undef, "$label cache is not reusable");
            ok(!exists $scope->{$key}, "$label cache entry is removed");
        }
    }
};

done_testing;
