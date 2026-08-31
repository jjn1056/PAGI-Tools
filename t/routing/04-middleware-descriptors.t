#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);
use PAGI::Routing qw(middleware);
use PAGI::Routing::Middleware;

{
    package DescriptorMiddlewareSubclass;
    our @ISA = ('PAGI::Routing::Middleware');
}

sub tracing_factory {
    my ($name, $builds) = @_;
    return sub {
        my ($app) = @_;
        push @$builds, $name;
        return sub {
            my ($scope, $receive, $send) = @_;
            push @{$scope->{trace}}, $name;
            return $app->($scope, $receive, $send);
        };
    };
}

sub install_class_loader {
    my ($wanted, $package) = @_;
    my $source = <<"CLASS_SOURCE";
package $package;
use strict;
use warnings;
no warnings 'redefine';
our \$NEW_CALLS = 0;
sub new {
    my (\$class, \%config) = \@_;
    ++\$NEW_CALLS;
    return bless { config => { \%config } }, \$class;
}
sub wrap {
    my (\$self, \$app) = \@_;
    my \$label = \$self->{config}{label};
    return sub {
        my (\$scope, \$receive, \$send) = \@_;
        push \@{\$scope->{trace}}, \$label;
        return \$app->(\$scope, \$receive, \$send);
    };
}
1;
CLASS_SOURCE

    return sub {
        my ($hook, $filename) = @_;
        return unless $filename eq $wanted;
        return \$source;
    };
}

subtest 'declarative lists normalize bare factories to descriptions' => sub {
    my $factory = sub { return $_[0] };
    my $explicit = middleware('Configured', enabled => 1);
    my $subclass = DescriptorMiddlewareSubclass->new(sub { return $_[0] });
    my $input = [$factory, $explicit, $factory, $subclass];

    my $normalized = PAGI::Routing::Middleware->_normalize_descriptors(
        $input,
        'middleware',
    );

    isnt(refaddr($normalized), refaddr($input), 'top-level input array is copied');
    isa_ok($normalized->[0], 'PAGI::Routing::Middleware');
    isa_ok($normalized->[2], 'PAGI::Routing::Middleware');
    is(refaddr($normalized->[0]->factory), refaddr($factory),
        'first generated description retains factory identity');
    is(refaddr($normalized->[2]->factory), refaddr($factory),
        'repeated occurrence retains the same factory identity');
    isnt(refaddr($normalized->[0]), refaddr($normalized->[2]),
        'repeated occurrences receive distinct descriptions');
    is(refaddr($normalized->[1]), refaddr($explicit),
        'explicit base description is preserved by identity');
    is(refaddr($normalized->[3]), refaddr($subclass),
        'explicit subclass description is preserved by identity');

    push @$input, middleware('LateMutation');
    is(scalar @$normalized, 4, 'later input mutation is invisible');
};

subtest 'normalization accepts all four entry forms and rejects invalid entries' => sub {
    is(
        PAGI::Routing::Middleware->_normalize_descriptors([], 'middleware'),
        [],
        'empty list normalizes to a fresh empty list',
    );
    like(
        dies {
            PAGI::Routing::Middleware->_normalize_descriptors({}, 'compose middleware')
        },
        qr/compose middleware must be an arrayref/,
        'caller prefix is retained for a non-array value',
    );

    my $factory = sub { return $_[0] };
    my $configured = bless {}, 'DescriptorConfiguredObject';
    my $explicit = middleware('Configured');
    my $normalized = PAGI::Routing::Middleware->_normalize_descriptors(
        ['GZip', $factory, $configured, $explicit],
        'middleware',
    );
    is($normalized->[0]->factory, 'GZip', 'direct class name becomes a description');
    is(refaddr($normalized->[1]->factory), refaddr($factory),
        'direct factory retains identity');
    is(refaddr($normalized->[2]->factory), refaddr($configured),
        'direct wrapping object retains identity');
    is(refaddr($normalized->[3]), refaddr($explicit),
        'explicit description retains identity');

    my $object_without_wrap = bless {}, 'DescriptorNoWrap';
    for my $invalid (42, [], {}, \do { my $value = 'reference' }, '',
            'not-a-package', $object_without_wrap,
            { header => 'X-Request-ID' }) {
        like(
            dies {
                PAGI::Routing::Middleware->_normalize_descriptors(
                    [$invalid],
                    'middleware',
                )
            },
            qr/middleware entry 0 must be a middleware class name/,
            'invalid direct entry reports its list index',
        );
    }
};

subtest 'the production fold keeps the first descriptor outermost' => sub {
    my @builds;
    my @descriptors = map {
        middleware(tracing_factory($_, \@builds))
    } qw(first second third);
    my $inner = sub {
        my ($scope) = @_;
        push @{$scope->{trace}}, 'inner';
        return Future->done('complete');
    };

    my $app = PAGI::Routing::Middleware->_wrap_descriptors(\@descriptors, $inner);

    is(\@builds, [qw(third second first)], 'reverse fold constructs from innermost outward');
    my $scope = { trace => [] };
    is($app->($scope, sub { }, sub { })->get, 'complete', 'wrapped app preserves inner result');
    is($scope->{trace}, [qw(first second third inner)], 'first listed wrapper executes outermost');
};

subtest 'an empty descriptor list preserves inner app identity' => sub {
    my $inner = sub { Future->done('inner') };
    my $app = PAGI::Routing::Middleware->_wrap_descriptors([], $inner);

    is(refaddr($app), refaddr($inner), 'empty reverse fold returns the exact inner app');
};

subtest 'a factory resolves once for each compiled wrapper' => sub {
    my $builds = 0;
    my $requests = 0;
    my $descriptor = middleware(sub {
        my ($app) = @_;
        ++$builds;
        return sub {
            ++$requests;
            return $app->(@_);
        };
    });
    my $inner = sub { Future->done('ok') };

    my $first_app = $descriptor->_wrap($inner);
    is($builds, 1, 'first compiled wrapper invokes factory once');
    $first_app->({}, sub { }, sub { })->get for 1 .. 3;
    is($builds, 1, 'requests do not resolve the factory again');
    is($requests, 3, 'compiled wrapper remains reusable across requests');

    my $second_app = $descriptor->_wrap($inner);
    is($builds, 2, 'a distinct compiled wrapper invokes factory once again');
    $second_app->({}, sub { }, sub { })->get;
    is($builds, 2, 'second wrapper also avoids request-time resolution');
};

subtest 'a configured object is used by identity' => sub {
    my @wrapped_by;
    my $object = bless { wrapped_by => \@wrapped_by }, 'DescriptorConfiguredObject';
    my $inner = sub { Future->done('inner') };

    my $app = middleware($object)->_wrap($inner);

    is(\@wrapped_by, [refaddr($object)], 'wrap was invoked on the exact configured object');
    is($app->({}, sub { }, sub { })->get, 'inner', 'object wrapper delegates to inner app');
};

subtest 'class names auto-load, receive config, and follow naming rules' => sub {
    my @cases = (
        ['RequestId', 'PAGI::Middleware::RequestId'],
        ['Auth::Basic', 'PAGI::Middleware::Auth::Basic'],
        ['PAGI::Middleware::RequestId', 'PAGI::Middleware::RequestId'],
        ['+Local::ExactMiddleware', 'Local::ExactMiddleware'],
    );

    for my $case (@cases) {
        my ($declared, $package) = @$case;
        (my $file = $package) =~ s{::}{/}g;
        $file .= '.pm';
        my $loader = install_class_loader($file, $package);
        local @INC = ($loader, @INC);
        delete local $INC{$file};
        my $scope = { trace => [] };
        my $inner = sub {
            my ($received) = @_;
            push @{$received->{trace}}, 'inner';
            return Future->done;
        };

        my $descriptor = middleware($declared, label => $declared);
        ok(!$INC{$file}, "$declared remains unloaded during description construction");
        my $app = $descriptor->_wrap($inner);
        $app->($scope, sub { }, sub { })->get;

        ok($INC{$file}, "$declared auto-loaded $package");
        no strict 'refs';
        is(${"${package}::NEW_CALLS"}, 1,
            "$declared constructs its middleware once during _wrap");
        is($scope->{trace}, [$declared, 'inner'], "$declared passed config through new and wrapped app");
    }

    like dies { middleware('^Local::OldEscape') },
        qr/invalid middleware class name|leading '\+'|exact package/i,
        'the retired caret exact-package spelling is rejected';
};

subtest 'a configured factory compiles application-valued results' => sub {
    local $Local::WrappedApplication::TO_APP_CALLS = 0;
    my @factory_calls;
    my $descriptor = middleware(sub {
        my ($inner, %config) = @_;
        push @factory_calls, [$inner, {%config}];
        return Local::WrappedApplication->new(inner => $inner);
    }, label => 'items', enabled => 1);
    my $inner = sub { return Future->done('inner') };

    is(\@factory_calls, [], 'description construction does not invoke the factory');
    my $first_app = $descriptor->_wrap($inner);
    is(scalar @factory_calls, 1, 'first _wrap invokes the factory once');
    is(refaddr($factory_calls[0][0]), refaddr($inner), 'factory receives the exact inner app');
    is($factory_calls[0][1], { label => 'items', enabled => 1 },
        'factory receives flat descriptor configuration');
    is($Local::WrappedApplication::TO_APP_CALLS, 1,
        'factory result is compiled through to_app once');
    is(ref($first_app), 'CODE', 'factory compilation returns a native app coderef');
    is($first_app->({}, sub { }, sub { })->get, 'inner',
        'factory application-valued result delegates to its inner app');

    my $second_app = $descriptor->_wrap($inner);
    isnt(refaddr($second_app), refaddr($first_app),
        'each _wrap creates a distinct compiled wrapper');
    is(scalar @factory_calls, 2, 'second _wrap invokes the factory once more');
    is($Local::WrappedApplication::TO_APP_CALLS, 2,
        'second factory result is also compiled once');
};

subtest 'configured objects compile application-valued wrap results' => sub {
    local $Local::WrappedApplication::TO_APP_CALLS = 0;
    my $object = DescriptorApplicationWrapObject->new;
    my $inner = sub { return Future->done('inner') };

    my $app = middleware($object)->_wrap($inner);

    is($object->{wrap_calls}, 1, 'configured object wraps once during _wrap');
    is($Local::WrappedApplication::TO_APP_CALLS, 1,
        'configured object wrap result is compiled through to_app once');
    is(ref($app), 'CODE', 'configured object compilation returns a native app coderef');
    is($app->({}, sub { }, sub { })->get, 'inner',
        'configured object application-valued result delegates to its inner app');
};

subtest 'invalid descriptor resolutions fail loudly' => sub {
    my $inner = sub { Future->done };

    for my $case (
        [sub { return undef }, qr/non-reference/i, 'undef factory result is rejected during _wrap'],
        [sub { return [] }, qr/ARRAY/i, 'arrayref factory result is rejected during _wrap'],
        [sub { return Future->done(sub { }) }, qr/Future/i,
            'async factory result is rejected during _wrap'],
    ) {
        my ($factory, $shape, $name) = @$case;
        like dies { middleware($factory)->_wrap($inner) },
            qr/middleware factory must return a PAGI application value:.*$shape/i,
            $name;
    }
    like(
        dies { middleware(bless {}, 'DescriptorNoWrap') },
        qr/middleware object.*wrap/i,
        'object without wrap is rejected',
    );
    my $configured = bless {}, 'DescriptorConfiguredObject';
    like(
        dies { middleware($configured, extra => 1) },
        qr/middleware object.*takes no config/i,
        'configured object plus constructor config is rejected',
    );
    like(
        dies { middleware(sub { die "factory exploded\n" })->_wrap($inner) },
        qr/factory exploded/,
        'factory exceptions propagate',
    );
};

subtest 'every intermediate wrapper result must be an app coderef' => sub {
    my $object = Local::BadWrapObject->new;
    my $inner = sub { Future->done };

    like(
        dies { middleware($object)->_wrap($inner) },
        qr/middleware wrap must return a PAGI application value:.*non-reference/i,
        'configured object wrap result is validated',
    );
};

{
    package DescriptorConfiguredObject;

    sub wrap {
        my ($self, $app) = @_;
        push @{$self->{wrapped_by}}, Scalar::Util::refaddr($self)
            if $self->{wrapped_by};
        return $app;
    }
}

{
    package Local::WrappedApplication;

    our $TO_APP_CALLS = 0;

    sub new {
        my ($class, %args) = @_;
        return bless \%args, $class;
    }
    sub to_app {
        my ($self) = @_;
        ++$TO_APP_CALLS;
        return sub { return $self->{inner}->(@_) };
    }
}

{
    package DescriptorApplicationWrapObject;

    sub new { return bless { wrap_calls => 0 }, shift }
    sub wrap {
        my ($self, $inner) = @_;
        ++$self->{wrap_calls};
        return Local::WrappedApplication->new(inner => $inner);
    }
}

{
    package Local::BadWrapObject;

    sub new { return bless {}, shift }
    sub wrap { return undef }
}

done_testing;
