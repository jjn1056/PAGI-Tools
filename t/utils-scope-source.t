use strict;
use warnings;
use Test2::V0;

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

done_testing;
