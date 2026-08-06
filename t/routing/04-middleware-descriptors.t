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
sub new {
    my (\$class, \%config) = \@_;
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

subtest 'normalization accepts only descriptions and coderef factories' => sub {
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

    my $configured = bless {}, 'DescriptorConfiguredObject';
    for my $invalid ('GZip', [], {}, 42, $configured) {
        like(
            dies {
                PAGI::Routing::Middleware->_normalize_descriptors(
                    [$invalid],
                    'middleware',
                )
            },
            qr/middleware must contain PAGI::Routing::Middleware descriptions or coderef factories/,
            'unsupported direct entry is rejected',
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
        [
            'DescriptorShort',
            'PAGI/Middleware/DescriptorShort.pm',
            'PAGI::Middleware::DescriptorShort',
            'short',
        ],
        [
            'Descriptor::Nested',
            'PAGI/Middleware/Descriptor/Nested.pm',
            'PAGI::Middleware::Descriptor::Nested',
            'nested',
        ],
        [
            'PAGI::Middleware::DescriptorQualified',
            'PAGI/Middleware/DescriptorQualified.pm',
            'PAGI::Middleware::DescriptorQualified',
            'qualified',
        ],
        [
            '^Caller::DescriptorExact',
            'Caller/DescriptorExact.pm',
            'Caller::DescriptorExact',
            'exact',
        ],
    );

    for my $case (@cases) {
        my ($declared, $file, $package, $label) = @$case;
        my $loader = install_class_loader($file, $package);
        local @INC = ($loader, @INC);
        delete local $INC{$file};
        my $scope = { trace => [] };
        my $inner = sub {
            my ($received) = @_;
            push @{$received->{trace}}, 'inner';
            return Future->done;
        };

        my $app = middleware($declared, label => $label)->_wrap($inner);
        $app->($scope, sub { }, sub { })->get;

        ok($INC{$file}, "$declared auto-loaded $package");
        is($scope->{trace}, [$label, 'inner'], "$declared passed config through new and wrapped app");
    }
};

subtest 'invalid descriptor resolutions fail loudly' => sub {
    my $inner = sub { Future->done };

    like(
        dies { middleware(sub { return 'not an app' })->_wrap($inner) },
        qr/middleware factory must return PAGI app coderef/i,
        'factory must return a coderef',
    );
    like(
        dies { middleware(sub { return Future->done(sub { }) })->_wrap($inner) },
        qr/middleware factory must return PAGI app coderef.*Future/i,
        'an accidental async factory is rejected as a Future',
    );
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
        dies { middleware(sub { return $_[0] }, label => 'audit') },
        qr/middleware factory.*takes no config/i,
        'coderef factory plus unused constructor config is rejected',
    );
    like(
        dies { middleware(sub { die "factory exploded\n" })->_wrap($inner) },
        qr/factory exploded/,
        'factory exceptions propagate',
    );
};

subtest 'every intermediate wrapper result must be an app coderef' => sub {
    my $object = bless {}, 'DescriptorBadWrapResult';
    my $inner = sub { Future->done };

    like(
        dies { middleware($object)->_wrap($inner) },
        qr/middleware wrap must return PAGI app coderef/i,
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
    package DescriptorBadWrapResult;

    sub wrap { return 'not an app' }
}

done_testing;
