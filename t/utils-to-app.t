use strict;
use warnings;

use Test2::V0;
use PAGI::Utils qw(to_app);

{
    package Local::UtilsDefaultImports;
    use PAGI::Utils;
}

{
    package Local::App;
    our $CALLS = 0;
    our $COMPILED = sub { return 'compiled' };
    sub new { return bless {}, $_[0] }
    sub to_app { $CALLS++; return $COMPILED }
}

{
    package Local::BrokenApp;
    sub new { return bless {}, $_[0] }
    sub to_app { return {} }
}

{
    package Local::Middleware;
    sub new { return bless {}, $_[0] }
    sub wrap { return $_[1] }
}

my $native = sub { return 'native' };
my $compiled = $Local::App::COMPILED;

is(to_app($native), $native, 'a native coderef is already an app');
is(to_app(Local::App->new), $compiled, 'an instantiated component compiles');
is($Local::App::CALLS, 1, 'an instantiated component compiles exactly once');
like(dies { to_app('Local::App') }, qr/instantiated object.*to_app/i,
    'a package name is never loaded as an app');
like(dies { to_app(Local::BrokenApp->new) }, qr/to_app.*coderef/i,
    'an object must compile to a native coderef');
like(dies { to_app(Local::Middleware->new) }, qr/middleware.*not an app/i,
    'middleware-object guidance remains specific');
like(dies { to_app([]) }, qr/coderef or instantiated object.*to_app/i,
    'unblessed references are not apps');
like(dies { to_app(undef) }, qr/coderef or instantiated object.*to_app/i,
    'undefined is not an app');
ok(!Local::UtilsDefaultImports->can('as_app'),
    'as_app is not exported by default');
ok(!Local::UtilsDefaultImports->can('invoke_app'),
    'invoke_app is not exported by default');

done_testing;
