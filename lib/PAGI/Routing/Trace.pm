package PAGI::Routing::Trace;

use strict;
use warnings;
use Carp qw(croak);
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use Scalar::Util qw(blessed refaddr);
use PAGI::Utils ();

my $COMPATIBILITY_MARKER = {};
my $WRITER_TOKEN = {};
my %TRACE_STATE;
my %CHECKPOINT_STATE;
my %LINK_STATE;

sub _same_reference {
    my ($left, $right) = @_;
    return 0 unless ref($left) && ref($right);
    return refaddr($left) == refaddr($right) ? 1 : 0;
}

sub _copy_value {
    my ($value) = @_;
    return [map { _copy_value($_) } @$value] if ref($value) eq 'ARRAY';
    if (ref($value) eq 'HASH') {
        return { map { $_ => _copy_value($value->{$_}) } keys %$value };
    }
    return $value;
}

sub _new {
    my ($class) = @_;
    my $self = bless {}, $class;
    $TRACE_STATE{refaddr($self)} = {
        compatibility   => $COMPATIBILITY_MARKER,
        identity        => {},
        sequence        => 0,
        next_frame      => 0,
        records         => [],
        frames          => {},
        details_resolved => 0,
        details_enabled  => 0,
        attempt_count    => 0,
        truncated        => 0,
    };
    return $self;
}

sub _state_for {
    my ($trace) = @_;
    return unless blessed($trace) && $trace->isa(__PACKAGE__);
    my $state = $TRACE_STATE{refaddr($trace)};
    return unless $state
        && _same_reference($state->{compatibility}, $COMPATIBILITY_MARKER);
    return $state;
}

sub _is_compatible {
    return _state_for($_[0]) ? 1 : 0;
}

sub _scope_is_http {
    my ($scope) = @_;
    return (($scope->{type} // 'http') eq 'http') ? 1 : 0;
}

sub _ensure_http_scope {
    my ($class, $scope) = @_;
    return ($scope, undef) unless _scope_is_http($scope);

    my $incoming = $scope->{'pagi.routing.trace'};
    return ($scope, $incoming) if _is_compatible($incoming);

    my $trace = $class->_new;
    my $inner = { %$scope, 'pagi.routing.trace' => $trace };
    return ($inner, $trace);
}

sub _fresh_http_scope {
    my ($class, $scope) = @_;
    return ($scope, undef) unless _scope_is_http($scope);

    my $trace = $class->_new;
    my $inner = { %$scope, 'pagi.routing.trace' => $trace };
    return ($inner, $trace);
}

sub checkpoint {
    my ($self) = @_;
    my $state = _state_for($self)
        or croak 'checkpoint requires a compatible routing trace';
    my $checkpoint = bless {}, 'PAGI::Routing::Trace::_Checkpoint';
    $CHECKPOINT_STATE{refaddr($checkpoint)} = {
        identity => $state->{identity},
        sequence => $state->{sequence},
    };
    return $checkpoint;
}

sub _checkpoint_state {
    my ($state, $checkpoint) = @_;
    my $checkpoint_state = blessed($checkpoint)
        && $checkpoint->isa('PAGI::Routing::Trace::_Checkpoint')
        ? $CHECKPOINT_STATE{refaddr($checkpoint)}
        : undef;
    croak 'checkpoint belongs to another routing trace'
        unless $checkpoint_state
            && _same_reference($checkpoint_state->{identity}, $state->{identity});
    return $checkpoint_state;
}

sub _discard_ranges {
    my ($state, $start, $end) = @_;
    my @ranges;
    for my $record (@{$state->{records}}) {
        next unless $record->{sequence} > $start
            && $record->{sequence} <= $end;
        next unless $record->{type} eq 'discard';
        push @ranges, [$record->{start}, $record->{end}];
    }
    return \@ranges;
}

sub _sequence_discarded {
    my ($sequence, $ranges) = @_;
    for my $range (@$ranges) {
        return 1 if $sequence > $range->[0] && $sequence <= $range->[1];
    }
    return 0;
}

sub _frame_summary {
    my ($state, $frame_id, $start, $end, $ranges, $seen) = @_;
    return unless !$seen->{$frame_id}++;
    my $frame = $state->{frames}{$frame_id} or return;
    return unless $frame->{completion};
    return unless $frame->{completion_sequence} > $start
        && $frame->{completion_sequence} <= $end;
    return if _sequence_discarded($frame->{completion_sequence}, $ranges);

    my $kind = $frame->{completion}{kind};
    if ($kind eq 'child') {
        return _frame_summary(
            $state,
            $frame->{completion}{child_frame_id},
            $start,
            $end,
            $ranges,
            $seen,
        );
    }
    return unless $kind eq 'decline';
    return $frame->{completion}{summary};
}

sub _snapshot_facts {
    my ($state, $start, $end) = @_;
    my $ranges = _discard_ranges($state, $start, $end);
    my %included;
    my @frames;

    my @completed_frame_ids = grep {
        $state->{frames}{$_}{completion}
    } keys %{$state->{frames}};
    for my $frame_id (sort {
        $state->{frames}{$a}{completion_sequence}
            <=> $state->{frames}{$b}{completion_sequence}
    } @completed_frame_ids) {
        my $frame = $state->{frames}{$frame_id};
        next unless $frame->{completion_sequence} > $start
            && $frame->{completion_sequence} <= $end;
        next if _sequence_discarded($frame->{completion_sequence}, $ranges);
        $included{$frame_id} = 1;
        push @frames, $frame_id;
    }

    my @roots = grep {
        my $parent = $state->{frames}{$_}{parent_frame_id};
        !defined($parent) || !$included{$parent};
    } @frames;

    my ($routing_declined, $path_matched, $method_matched) = (0, 0, 0);
    my (@allowed_methods, %allowed_seen);
    for my $frame_id (@roots) {
        my $summary = _frame_summary(
            $state,
            $frame_id,
            $start,
            $end,
            $ranges,
            {},
        );
        next unless $summary;
        $routing_declined = 1;
        $path_matched ||= $summary->{path_matched} ? 1 : 0;
        $method_matched ||= $summary->{method_matched} ? 1 : 0;
        for my $method (@{$summary->{allowed_methods} || []}) {
            push @allowed_methods, $method unless $allowed_seen{$method}++;
        }
    }

    my @attempts;
    if ($state->{details_enabled}) {
        for my $record (@{$state->{records}}) {
            next unless $record->{sequence} > $start
                && $record->{sequence} <= $end;
            next unless $record->{type} eq 'attempt';
            next if _sequence_discarded($record->{sequence}, $ranges);
            push @attempts, _copy_value($record->{record});
        }
    }

    return {
        routing_declined  => $routing_declined ? 1 : 0,
        path_matched      => $path_matched ? 1 : 0,
        method_matched    => $method_matched ? 1 : 0,
        allowed_methods   => \@allowed_methods,
        attempts          => \@attempts,
        details_available => $state->{details_enabled} ? 1 : 0,
        truncated         => $state->{truncated} ? 1 : 0,
    };
}

sub snapshot {
    my ($self, $checkpoint) = @_;
    my $state = _state_for($self)
        or croak 'snapshot requires a compatible routing trace';
    my $checkpoint_state = _checkpoint_state($state, $checkpoint);
    my $facts = _snapshot_facts(
        $state,
        $checkpoint_state->{sequence},
        $state->{sequence},
    );
    require PAGI::Routing::Trace::Snapshot;
    return PAGI::Routing::Trace::Snapshot->_new($facts);
}

sub _append_record {
    my ($state, $record) = @_;
    $record->{sequence} = ++$state->{sequence};
    push @{$state->{records}}, $record;
    return $record->{sequence};
}

sub _frame_for_write {
    my ($state, $frame_id) = @_;
    my $frame = $state->{frames}{$frame_id};
    croak 'routing trace frame is invalid' unless $frame;
    croak 'routing trace frame is already complete' if $frame->{completion};
    return $frame;
}

sub _write {
    my ($trace, $presented_token, $operation, @arguments) = @_;
    croak 'routing Trace Recorder requires its private capability'
        unless _same_reference($presented_token, $WRITER_TOKEN);
    my $state = _state_for($trace)
        or croak 'routing Trace Recorder requires a compatible collector';
    return 1 if $operation eq 'verify';

    if ($operation eq 'begin_frame') {
        my ($meta, $parent_link) = @arguments;
        croak 'routing frame metadata must be a hash reference'
            unless ref($meta) eq 'HASH';
        my $parent_frame_id;
        if (defined $parent_link) {
            my $link = blessed($parent_link)
                && $parent_link->isa('PAGI::Routing::Trace::_ParentLink')
                ? $LINK_STATE{refaddr($parent_link)}
                : undef;
            croak 'routing parent link is invalid'
                unless $link
                    && _same_reference($link->{identity}, $state->{identity});
            croak 'routing parent link has already been consumed'
                if $link->{consumed};
            my $parent = _frame_for_write($state, $link->{parent_frame_id});
            croak 'routing parent frame is not expecting this child'
                unless $parent->{expected_link}
                    && _same_reference($parent->{expected_link}, $parent_link);
            $link->{consumed} = 1;
            $parent_frame_id = $link->{parent_frame_id};
        }
        my $frame_id = ++$state->{next_frame};
        my $sequence = _append_record($state, {
            type     => 'frame_begin',
            frame_id => $frame_id,
            meta     => { %$meta },
        });
        $state->{frames}{$frame_id} = {
            begin_sequence  => $sequence,
            parent_frame_id => $parent_frame_id,
            meta            => { %$meta },
        };
        if (defined $parent_link) {
            $LINK_STATE{refaddr($parent_link)}{child_frame_id} = $frame_id;
        }
        unless ($state->{details_resolved}) {
            $state->{details_enabled}
                = PAGI::Utils::is_development() ? 1 : 0;
            $state->{details_resolved} = 1;
        }
        return $frame_id;
    }

    my ($frame_id, @rest) = @arguments;
    my $frame = _frame_for_write($state, $frame_id);

    if ($operation eq 'attempt') {
        my ($record) = @rest;
        croak 'routing attempt must be a hash reference'
            unless ref($record) eq 'HASH';
        return unless $state->{details_enabled};
        if ($state->{attempt_count} >= 256) {
            $state->{truncated} = 1;
            return;
        }
        ++$state->{attempt_count};
        _append_record($state, {
            type     => 'attempt',
            frame_id => $frame_id,
            record   => _copy_value($record),
        });
        return;
    }

    if ($operation eq 'select_leaf' || $operation eq 'select_opaque') {
        croak 'routing frame already has a selection' if $frame->{selection};
        $frame->{selection} = $operation eq 'select_leaf' ? 'leaf' : 'opaque';
        _append_record($state, {
            type      => 'selection',
            frame_id  => $frame_id,
            selection => $frame->{selection},
        });
        return;
    }

    if ($operation eq 'expect_child') {
        croak 'routing frame already has a selection' if $frame->{selection};
        my $link = bless {}, 'PAGI::Routing::Trace::_ParentLink';
        $LINK_STATE{refaddr($link)} = {
            identity        => $state->{identity},
            parent_frame_id => $frame_id,
            consumed        => 0,
        };
        $frame->{selection} = 'child';
        $frame->{expected_link} = $link;
        _append_record($state, {
            type     => 'expect_child',
            frame_id => $frame_id,
        });
        return $link;
    }

    my $completion;
    if ($operation eq 'complete_decline') {
        my ($summary) = @rest;
        croak 'routing decline summary must be a hash reference'
            unless ref($summary) eq 'HASH';
        $completion = {
            kind => 'decline',
            summary => {
                routing_declined => 1,
                path_matched => $summary->{path_matched} ? 1 : 0,
                method_matched => $summary->{method_matched} ? 1 : 0,
                allowed_methods => [@{$summary->{allowed_methods} || []}],
            },
        };
    }
    elsif ($operation eq 'complete_success') {
        $completion = { kind => 'success' };
    }
    elsif ($operation eq 'complete_exception') {
        $completion = { kind => 'exception' };
    }
    elsif ($operation eq 'complete_child') {
        my ($child_link) = @rest;
        my $link = blessed($child_link)
            && $child_link->isa('PAGI::Routing::Trace::_ParentLink')
            ? $LINK_STATE{refaddr($child_link)}
            : undef;
        croak 'routing parent link is invalid'
            unless $link
                && _same_reference($link->{identity}, $state->{identity})
                && $link->{parent_frame_id} == $frame_id
                && $frame->{expected_link}
                && _same_reference($frame->{expected_link}, $child_link);
        croak 'routing parent link was not consumed by a child'
            unless $link->{consumed} && defined $link->{child_frame_id};
        my $child = $state->{frames}{$link->{child_frame_id}};
        croak 'routing child frame is not complete'
            unless $child && $child->{completion};
        $completion = {
            kind           => 'child',
            child_frame_id => $link->{child_frame_id},
        };
    }
    else {
        croak 'unsupported routing Trace Recorder operation';
    }

    $frame->{completion} = $completion;
    $frame->{completion_sequence} = _append_record($state, {
        type       => 'frame_complete',
        frame_id   => $frame_id,
        completion => $completion,
    });
    return;
}

sub _discard_window {
    my ($trace, $checkpoint) = @_;
    my $state = _state_for($trace)
        or croak 'discarded routing window requires a compatible collector';
    my $checkpoint_state = _checkpoint_state($state, $checkpoint);
    my $end = $state->{sequence};
    _append_record($state, {
        type  => 'discard',
        start => $checkpoint_state->{sequence},
        end   => $end,
    });
    return;
}

sub _canonical_source {
    my ($source) = @_;
    return abs_path($source) || File::Spec->canonpath(File::Spec->rel2abs($source));
}

sub _expected_source {
    my (@parts) = @_;
    return _canonical_source(File::Spec->catfile(dirname(__FILE__), @parts));
}

sub _seal_claim {
    my ($name, $diagnostic) = @_;
    no strict 'refs';
    no warnings 'redefine';
    *{__PACKAGE__ . "::$name"} = sub { croak $diagnostic };
    return;
}

sub _claim_compiler_recorder_factory {
    my ($class, $installer) = @_;
    my ($package, $source) = caller;
    croak 'compiler recorder factory may only be claimed by PAGI::Routing::Compiler'
        unless $package eq 'PAGI::Routing::Compiler'
            && _canonical_source($source) eq _expected_source('Compiler.pm');
    croak 'compiler recorder factory installer must be a code reference'
        unless ref($installer) eq 'CODE';

    require PAGI::Routing::Trace::Recorder;
    $installer->(sub {
        my ($trace) = @_;
        return PAGI::Routing::Trace::Recorder->_new(
            $trace,
            $WRITER_TOKEN,
            \&_write,
        );
    });
    _seal_claim(
        '_claim_compiler_recorder_factory',
        'compiler recorder factory is permanently sealed',
    );
    return;
}

sub _claim_cascade_discard_factory {
    my ($class, $installer) = @_;
    my ($package, $source) = caller;
    croak 'Cascade discard factory may only be claimed by PAGI::App::Cascade'
        unless $package eq 'PAGI::App::Cascade'
            && _canonical_source($source)
                eq _expected_source(File::Spec->updir, 'App', 'Cascade.pm');
    croak 'Cascade discard factory installer must be a code reference'
        unless ref($installer) eq 'CODE';

    $installer->(sub { return _discard_window(@_) });
    _seal_claim(
        '_claim_cascade_discard_factory',
        'Cascade discard factory is permanently sealed',
    );
    return;
}

sub DESTROY {
    my ($self) = @_;
    delete $TRACE_STATE{refaddr($self)};
    return;
}

package PAGI::Routing::Trace::_Checkpoint;

sub DESTROY {
    my ($self) = @_;
    delete $CHECKPOINT_STATE{Scalar::Util::refaddr($self)};
    return;
}

package PAGI::Routing::Trace::_ParentLink;

sub DESTROY {
    my ($self) = @_;
    delete $LINK_STATE{Scalar::Util::refaddr($self)};
    return;
}

1;

__END__

=head1 NAME

PAGI::Routing::Trace - Request-local read-only routing evidence

=head1 DESCRIPTION

C<PAGI::Routing::Trace> is the first-party collector stored under the
C<pagi.routing.trace> HTTP scope key. Installation shallow-clones the scope
when a collector must be installed or replaced. Compatible collectors are
shared by identity through nested HTTP scopes. Non-HTTP scopes are returned
unchanged and a same-named value on them remains ordinary scope data.

The supported observer operations are L</checkpoint> and L</snapshot>. The
collector has no public mutation API. Compiler recording and Cascade discard
capabilities are internal, sealed implementation details and are unsupported.

=head1 METHODS

=head2 checkpoint

Returns an opaque marker owned by this collector. It does not clear or consume
routing evidence.

=head2 snapshot

Returns a L<PAGI::Routing::Trace::Snapshot> for evidence appended since the
given checkpoint. A checkpoint from another collector is rejected. Snapshot
arrays are defensive copies, detailed attempts are available only when the
development environment gate was enabled by compiler activity, and retained
attempts are bounded to 256 per request.

=cut
