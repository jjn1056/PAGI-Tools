use strict;
use warnings;
use Test2::V0;

use PAGI::Transport qw(transport);
use PAGI::Request;
use PAGI::WebSocket;
use PAGI::SSE;
use PAGI::Context;

{
    package Local::Transport::NoDefault;
    PAGI::Transport->import;
}

{
    package Local::Transport::Named;
    PAGI::Transport->import('transport');
}

{
    package Local::Transport::All;
    PAGI::Transport->import(':ALL');
}

{
    package MockTransport;
    sub new {
        return bless {
            buf  => $_[1],
            high => $_[2],
            low  => $_[3],
            hw   => [],
            dr   => [],
        }, $_[0];
    }
    sub buffered_amount { return $_[0]{buf} }
    sub high_water_mark { return $_[0]{high} }
    sub low_water_mark  { return $_[0]{low} }
    sub on_high_water {
        push @{$_[0]{hw}}, $_[1];
        return $_[0];
    }
    sub on_drain {
        push @{$_[0]{dr}}, $_[1];
        return $_[0];
    }
}

{
    package ReadsOnlyTransport;
    sub new {
        return bless { buf => $_[1], high => $_[2], low => $_[3] }, $_[0];
    }
    sub buffered_amount { return $_[0]{buf} }
    sub high_water_mark { return $_[0]{high} }
    sub low_water_mark  { return $_[0]{low} }
}

{
    package BufferedOnlyTransport;
    sub new { return bless { buf => $_[1] }, $_[0] }
    sub buffered_amount { return $_[0]{buf} }
}

ok(!Local::Transport::NoDefault->can('transport'),
    'transport is not exported by default');
ok(Local::Transport::Named->can('transport'),
    'transport is available as a named export');
ok(Local::Transport::All->can('transport'),
    'uppercase :ALL exports transport');

my $lowercase_tag_error;
{
    local $SIG{__WARN__} = sub { };
    $lowercase_tag_error = dies { PAGI::Transport->import(':all') };
}
like($lowercase_tag_error, qr/"?:all"? is not defined|Can't continue/i,
    'lowercase :all is not an export tag');

subtest 'transport is optional and does not cache in scope' => sub {
    my $scope = { type => 'http' };
    my @keys_before = sort keys %{$scope};

    is(transport($scope), undef, 'transport is optional');
    is([sort keys %{$scope}], \@keys_before, 'absent facade adds no scope cache key');

    $scope->{'pagi.transport'} = MockTransport->new(4096, 65536, 16384);
    my @present_keys = sort keys %{$scope};
    my $first = transport($scope);
    my $second = transport($scope);
    isa_ok($first, ['PAGI::Transport']);
    isa_ok($second, ['PAGI::Transport']);
    is([sort keys %{$scope}], \@present_keys, 'present facade adds no scope cache key');
};

subtest 'required and optional read capabilities' => sub {
    my $flow = transport({
        type             => 'http',
        'pagi.transport' => MockTransport->new(4096, 65536, 16384),
    });

    is($flow->buffered_amount, 4096, 'buffered amount delegates');
    is($flow->high_water_mark, 65536, 'high watermark delegates');
    is($flow->low_water_mark, 16384, 'low watermark delegates');
    ok($flow->is_writable, 'buffer below high watermark is writable');

    my $minimal = transport({
        type             => 'http',
        'pagi.transport' => BufferedOnlyTransport->new(12),
    });
    is($minimal->high_water_mark, undef, 'missing high watermark degrades to undef');
    is($minimal->low_water_mark, undef, 'missing low watermark degrades to undef');
    ok($minimal->is_writable, 'missing high watermark is assumed writable');
};

subtest 'callback registration delegates and chains' => sub {
    my $handle = MockTransport->new(0, 65536, 16384);
    my $flow = transport({ type => 'http', 'pagi.transport' => $handle });
    my $high_callback = sub { };
    my $drain_callback = sub { };

    is($flow->on_high_water($high_callback), exact_ref($flow),
        'high callback registration chains');
    is($flow->on_drain($drain_callback), exact_ref($flow),
        'drain callback registration chains');
    is($handle->{hw}, [exact_ref($high_callback)], 'high callback reaches the handle');
    is($handle->{dr}, [exact_ref($drain_callback)], 'drain callback reaches the handle');

    my $reads_only = transport({
        type             => 'http',
        'pagi.transport' => ReadsOnlyTransport->new(0, 65536, 16384),
    });
    is($reads_only->on_high_water(sub { }), exact_ref($reads_only),
        'missing high callback capability is a chaining no-op');
    is($reads_only->on_drain(sub { }), exact_ref($reads_only),
        'missing drain callback capability is a chaining no-op');
};

subtest 'writability stops at the high watermark boundary' => sub {
    ok(!transport({
        type             => 'http',
        'pagi.transport' => MockTransport->new(65536, 65536, 16384),
    })->is_writable, 'buffer at high watermark is not writable');
    ok(!transport({
        type             => 'http',
        'pagi.transport' => MockTransport->new(70000, 65536, 16384),
    })->is_writable, 'buffer above high watermark is not writable');
};

subtest 'present handle must provide buffered_amount' => sub {
    like(dies {
        transport({ 'pagi.transport' => bless({}, 'Bad') });
    }, qr/transport.*buffered_amount/i, 'malformed handle is rejected');
};

subtest 'strict source normalization supports protocol objects' => sub {
    my $receive = sub { };
    my $send = sub { };
    my $request_scope = {
        type             => 'http',
        method           => 'GET',
        headers          => [],
        'pagi.transport' => MockTransport->new(101, 200, 50),
    };
    my $request = PAGI::Request->new($request_scope, $receive);
    is(transport($request)->buffered_amount, 101,
        'strict Request source resolves its scope');

    my $websocket = PAGI::WebSocket->new({
        type             => 'websocket',
        headers          => [],
        'pagi.transport' => MockTransport->new(102, 200, 50),
    }, $receive, $send);
    is(transport($websocket)->buffered_amount, 102,
        'WebSocket source resolves its scope');

    my $sse = PAGI::SSE->new({
        type             => 'sse',
        headers          => [],
        'pagi.transport' => MockTransport->new(103, 200, 50),
    }, $receive, $send);
    is(transport($sse)->buffered_amount, 103, 'SSE source resolves its scope');

    my $context = PAGI::Context->new({
        type             => 'http',
        method           => 'GET',
        headers          => [],
        'pagi.transport' => MockTransport->new(104, 200, 50),
    }, $receive, $send);
    is(transport($context)->buffered_amount, 104, 'Context source resolves its scope');

    like(dies { PAGI::Transport->new() }, qr/exactly one.*scope/i,
        'constructor rejects a missing source');
    like(dies { transport($request_scope, $request_scope) }, qr/exactly one.*scope/i,
        'factory rejects multiple sources');
};

subtest 'Context, WebSocket, and SSE compatibility convenience remains' => sub {
    my $receive = sub { };
    my $send = sub { };
    my @cases = (
        ['PAGI::Context', sub {
            my ($handle) = @_;
            my $scope = { type => 'http', method => 'GET', headers => [] };
            $scope->{'pagi.transport'} = $handle if defined $handle;
            return PAGI::Context->new($scope, $receive, $send);
        }],
        ['PAGI::WebSocket', sub {
            my ($handle) = @_;
            my $scope = { type => 'websocket', headers => [] };
            $scope->{'pagi.transport'} = $handle if defined $handle;
            return PAGI::WebSocket->new($scope, $receive, $send);
        }],
        ['PAGI::SSE', sub {
            my ($handle) = @_;
            my $scope = { type => 'sse', headers => [] };
            $scope->{'pagi.transport'} = $handle if defined $handle;
            return PAGI::SSE->new($scope, $receive, $send);
        }],
    );

    for my $case (@cases) {
        my ($name, $build) = @{$case};
        my $handle = MockTransport->new(11, 22, 5);
        my $object = $build->($handle);
        my $high_callback = sub { };
        my $drain_callback = sub { };

        is($object->buffered_amount, 11, "$name keeps buffered_amount");
        is($object->high_water_mark, 22, "$name keeps high_water_mark");
        is($object->low_water_mark, 5, "$name keeps low_water_mark");
        ok($object->is_writable, "$name keeps is_writable");
        is($object->on_high_water($high_callback), exact_ref($object),
            "$name high callback still chains");
        is($object->on_drain($drain_callback), exact_ref($object),
            "$name drain callback still chains");
        is($handle->{hw}, [exact_ref($high_callback)],
            "$name high callback still delegates");
        is($handle->{dr}, [exact_ref($drain_callback)],
            "$name drain callback still delegates");

        my $without = $build->(undef);
        is($without->buffered_amount, 0, "$name keeps absent buffered default");
        is($without->high_water_mark, undef, "$name keeps absent high default");
        is($without->low_water_mark, undef, "$name keeps absent low default");
        ok($without->is_writable, "$name keeps absent writable default");

        my $reads_only = $build->(ReadsOnlyTransport->new(0, 22, 5));
        is($reads_only->on_high_water(sub { }), exact_ref($reads_only),
            "$name missing high callback stays a chaining no-op");
        is($reads_only->on_drain(sub { }), exact_ref($reads_only),
            "$name missing drain callback stays a chaining no-op");
    }
};

done_testing;
