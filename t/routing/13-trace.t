use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);

use PAGI::Routing::Trace;
use PAGI::Routing::Trace::Recorder;
use PAGI::Routing::Trace::Snapshot;

subtest 'HTTP trace installation is request-local and compatible' => sub {
    my $scope = { type => 'http', path => '/' };
    my ($inner, $trace)
        = PAGI::Routing::Trace->_ensure_http_scope($scope);

    isnt(refaddr($inner), refaddr($scope),
        'installation uses a shallow clone');
    isa_ok($inner->{'pagi.routing.trace'}, 'PAGI::Routing::Trace');
    is($scope->{'pagi.routing.trace'}, undef, 'incoming scope is untouched');
    ok(!$trace->can('record_attempt'),
        'public collector has no mutation API');

    my ($reused_scope, $reused_trace)
        = PAGI::Routing::Trace->_ensure_http_scope($inner);
    is(refaddr($reused_scope), refaddr($inner),
        'a compatible scope is reused');
    is(refaddr($reused_trace), refaddr($trace),
        'a compatible first-party Trace is reused');
};

subtest 'incompatible incoming values are replaced without mutation' => sub {
    my $hash_value = {};
    my $hash_scope = {
        type                 => 'http',
        path                 => '/hash',
        'pagi.routing.trace' => $hash_value,
    };
    my ($hash_inner, $hash_trace)
        = PAGI::Routing::Trace->_ensure_http_scope($hash_scope);

    isnt(refaddr($hash_inner), refaddr($hash_scope),
        'a malformed hash value causes a shallow clone');
    is($hash_scope->{'pagi.routing.trace'}, $hash_value,
        'the malformed hash remains on the incoming scope');
    is($hash_inner->{'pagi.routing.trace'}, $hash_trace,
        'the replacement Trace is installed on the clone');
    isa_ok($hash_trace, 'PAGI::Routing::Trace');

    my $object_value = bless {}, 'Local::TraceLookalike';
    my $object_scope = {
        type                 => 'http',
        path                 => '/object',
        'pagi.routing.trace' => $object_value,
    };
    my ($object_inner, $object_trace)
        = PAGI::Routing::Trace->_ensure_http_scope($object_scope);

    isnt(refaddr($object_inner), refaddr($object_scope),
        'an incompatible object causes a shallow clone');
    is($object_scope->{'pagi.routing.trace'}, $object_value,
        'the incompatible object remains on the incoming scope');
    isa_ok($object_trace, 'PAGI::Routing::Trace');
};

subtest 'fresh HTTP installation replaces a compatible collector' => sub {
    my ($installed_scope, $installed_trace)
        = PAGI::Routing::Trace->_ensure_http_scope({ type => 'http' });
    my ($fresh_scope, $fresh_trace)
        = PAGI::Routing::Trace->_fresh_http_scope($installed_scope);

    isnt(refaddr($fresh_scope), refaddr($installed_scope),
        'fresh installation uses a shallow clone');
    isnt(refaddr($fresh_trace), refaddr($installed_trace),
        'fresh installation replaces a compatible Trace');
    is($installed_scope->{'pagi.routing.trace'}, $installed_trace,
        'fresh installation leaves the incoming scope untouched');
    is($fresh_scope->{'pagi.routing.trace'}, $fresh_trace,
        'fresh installation stores only the new Trace');
};

subtest 'non-HTTP scopes are never installed or mutated' => sub {
    my ($http_scope, $http_trace)
        = PAGI::Routing::Trace->_ensure_http_scope({ type => 'http' });

    for my $case (
        ['websocket', undef],
        ['sse', bless({}, 'Local::NonHTTPValue')],
        ['lifespan', $http_trace],
    ) {
        my ($type, $incoming) = @$case;
        my $scope = { type => $type, marker => $type };
        $scope->{'pagi.routing.trace'} = $incoming if defined $incoming;

        my ($ensured_scope, $ensured_trace)
            = PAGI::Routing::Trace->_ensure_http_scope($scope);
        is(refaddr($ensured_scope), refaddr($scope),
            "$type ensure preserves scope identity");
        is($ensured_trace, undef, "$type ensure returns no Trace");
        is($ensured_scope, $scope, "$type ensure leaves scope data unchanged");

        my ($fresh_scope, $fresh_trace)
            = PAGI::Routing::Trace->_fresh_http_scope($scope);
        is(refaddr($fresh_scope), refaddr($scope),
            "$type fresh preserves scope identity");
        is($fresh_trace, undef, "$type fresh returns no Trace");
        is($fresh_scope, $scope, "$type fresh leaves scope data unchanged");
    }
};

subtest 'empty checkpoint snapshots are immutable and collector-owned' => sub {
    my (undef, $trace) = PAGI::Routing::Trace->_ensure_http_scope({
        type => 'http',
    });
    my $checkpoint = $trace->checkpoint;
    my $snapshot = $trace->snapshot($checkpoint);

    isa_ok($snapshot, 'PAGI::Routing::Trace::Snapshot');
    ok(!$snapshot->routing_declined, 'an empty window did not decline');
    ok(!$snapshot->path_matched, 'an empty window has no path match');
    ok(!$snapshot->method_matched, 'an empty window has no method match');
    is($snapshot->allowed_methods, [], 'an empty window has no allowed methods');
    is($snapshot->attempts, [], 'an empty window has no attempts');
    ok(!$snapshot->details_available,
        'an empty window has no development details');
    ok(!$snapshot->truncated, 'an empty window is not truncated');

    my $allowed = $snapshot->allowed_methods;
    my $attempts = $snapshot->attempts;
    push @$allowed, 'PATCH';
    push @$attempts, { kind => 'forged' };
    is($snapshot->allowed_methods, [],
        'allowed methods are returned as a fresh defensive array');
    is($snapshot->attempts, [],
        'attempts are returned as a fresh defensive array');

    $checkpoint->{collector} = 'forged';
    $snapshot->{routing_declined} = 1;
    ok(!$snapshot->routing_declined,
        'direct hash mutation cannot alter snapshot facts');
    my $same_snapshot = $trace->snapshot($checkpoint);
    ok(!$same_snapshot->routing_declined,
        'direct hash mutation cannot alter checkpoint ownership');

    my (undef, $other_trace)
        = PAGI::Routing::Trace->_ensure_http_scope({ type => 'http' });
    like(
        dies { $other_trace->snapshot($checkpoint) },
        qr/checkpoint belongs to another routing trace/,
        'a foreign collector rejects the checkpoint',
    );
};

subtest 'empty windows do not inherit prior detail state' => sub {
    my $state = {
        records => [
            { sequence => 1, type => 'details_available' },
            { sequence => 2, type => 'details_truncated' },
        ],
        frames          => {},
        details_enabled => 1,
        truncated       => 1,
    };
    my $prior = PAGI::Routing::Trace::Snapshot->_new(
        PAGI::Routing::Trace::_snapshot_facts($state, 0, 2),
    );
    ok($prior->details_available,
        'a window containing compiler detail activity reports details');
    ok($prior->truncated,
        'a window containing a truncation record reports truncation');

    my $checkpoint_after_activity = 2;
    my $empty = PAGI::Routing::Trace::Snapshot->_new(
        PAGI::Routing::Trace::_snapshot_facts(
            $state,
            $checkpoint_after_activity,
            $checkpoint_after_activity,
        ),
    );
    ok(!$empty->details_available,
        'a later empty window does not inherit prior detail availability');
    ok(!$empty->truncated,
        'a later empty window does not inherit prior truncation');
};

subtest 'mutation capabilities are private and sealed' => sub {
    my ($scope, $trace) = PAGI::Routing::Trace->_ensure_http_scope({
        type => 'http',
        path => '/capabilities',
    });
    my @writes = qw(
        _begin_frame _attempt _select_leaf _select_opaque _expect_child
        _complete_decline _complete_success _complete_child
        _complete_exception
    );

    ok(!$trace->can($_), "Trace does not expose $_") for @writes;
    ok(!$trace->can('_discard_window'),
        'Trace does not expose the Cascade discard mutation');
    my $direct_checkpoint = $trace->checkpoint;
    like(
        dies { $trace->_discard_window($direct_checkpoint) },
        qr/Can't locate object method "_discard_window"/,
        'ordinary middleware cannot append a trusted discard window',
    );
    ok(!PAGI::Routing::Trace::Snapshot->can($_),
        "Snapshot does not expose $_") for @writes;
    ok(!PAGI::Routing::Trace::Recorder->can('new'),
        'Recorder has no public constructor');
    like(
        dies {
            PAGI::Routing::Trace::Recorder->_new($trace, undef, undef);
        },
        qr/routing Trace Recorder requires its private capability/,
        'Recorder cannot be constructed without the private capability',
    );
    like(
        dies {
            PAGI::Routing::Trace::Recorder->_new($trace, {}, sub { 1 });
        },
        qr/routing Trace Recorder requires its private capability/,
        'a caller-provided token and verifier cannot forge a Recorder',
    );

    like(
        dies {
            PAGI::Routing::Trace->_claim_compiler_recorder_factory(sub {});
        },
        qr/compiler recorder factory may only be claimed by PAGI::Routing::Compiler/,
        'an ordinary caller cannot claim the compiler factory',
    );
    like(
        dies {
            PAGI::Routing::Trace->_claim_cascade_discard_factory(sub {});
        },
        qr/Cascade discard factory may only be claimed by PAGI::App::Cascade/,
        'an ordinary caller cannot claim the Cascade factory',
    );

    {
        package PAGI::Routing::Compiler;
        sub _local_test_claim {
            return PAGI::Routing::Trace
                ->_claim_compiler_recorder_factory(sub {});
        }
    }
    {
        package PAGI::App::Cascade;
        sub _local_test_claim {
            return PAGI::Routing::Trace
                ->_claim_cascade_discard_factory(sub {});
        }
    }
    like(
        dies { PAGI::Routing::Compiler->_local_test_claim },
        qr/compiler recorder factory may only be claimed by PAGI::Routing::Compiler/,
        'the right package cannot claim the compiler factory from another source',
    );
    like(
        dies { PAGI::App::Cascade->_local_test_claim },
        qr/Cascade discard factory may only be claimed by PAGI::App::Cascade/,
        'the right package cannot claim the Cascade factory from another source',
    );

    require PAGI::Routing::Compiler;
    require PAGI::App::Cascade;

    like(
        dies {
            PAGI::Routing::Trace->_claim_compiler_recorder_factory(sub {});
        },
        qr/compiler recorder factory is permanently sealed/,
        'the compiler factory cannot be reclaimed',
    );
    like(
        dies {
            PAGI::Routing::Trace->_claim_cascade_discard_factory(sub {});
        },
        qr/Cascade discard factory is permanently sealed/,
        'the Cascade factory cannot be reclaimed',
    );

    is([sort keys %$scope],
        [sort qw(path type pagi.routing.trace)],
        'scope contains no capability transport key');
    is([keys %$trace], [],
        'the Trace representation contains no writer, discard, or token');
    ok(!$scope->{'pagi.routing.trace'}->isa('PAGI::Routing::Trace::Recorder'),
        'scope stores only the read-only collector');
    ok(!PAGI::App::Cascade->can($_),
        "Cascade cannot perform compiler write $_") for @writes;
};

done_testing;
