package PAGI::Routing::Trace::Recorder;

use strict;
use warnings;
use Carp qw(croak);
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use Scalar::Util qw(refaddr);

my %RECORDER_STATE;

sub _new {
    my ($class, $trace, $token, $write) = @_;
    my ($package, $source) = caller;
    my $expected_source = File::Spec->catfile(
        dirname(__FILE__),
        File::Spec->updir,
        'Trace.pm',
    );
    my $actual = abs_path($source)
        || File::Spec->canonpath(File::Spec->rel2abs($source));
    my $expected = abs_path($expected_source)
        || File::Spec->canonpath(File::Spec->rel2abs($expected_source));
    croak 'routing Trace Recorder requires its private capability'
        unless $package eq 'PAGI::Routing::Trace'
            && $actual eq $expected
            && ref($token)
            && ref($write) eq 'CODE';
    $write->($trace, $token, 'verify');

    my $self = bless {}, $class;
    $RECORDER_STATE{refaddr($self)} = {
        trace => $trace,
        token => $token,
        write => $write,
    };
    return $self;
}

sub _invoke {
    my ($self, $operation, @arguments) = @_;
    my $state = $RECORDER_STATE{refaddr($self)}
        or croak 'routing Trace Recorder requires its private capability';
    return $state->{write}->(
        $state->{trace},
        $state->{token},
        $operation,
        @arguments,
    );
}

sub _begin_frame {
    my ($self, $meta, $parent_link) = @_;
    return $self->_invoke('begin_frame', $meta, $parent_link);
}

sub _attempt {
    my ($self, $frame_id, $record) = @_;
    return $self->_invoke('attempt', $frame_id, $record);
}

sub _select_leaf {
    my ($self, $frame_id) = @_;
    return $self->_invoke('select_leaf', $frame_id);
}

sub _select_opaque {
    my ($self, $frame_id) = @_;
    return $self->_invoke('select_opaque', $frame_id);
}

sub _expect_child {
    my ($self, $frame_id) = @_;
    return $self->_invoke('expect_child', $frame_id);
}

sub _complete_decline {
    my ($self, $frame_id, $summary) = @_;
    return $self->_invoke('complete_decline', $frame_id, $summary);
}

sub _complete_success {
    my ($self, $frame_id) = @_;
    return $self->_invoke('complete_success', $frame_id);
}

sub _complete_child {
    my ($self, $frame_id, $child_link) = @_;
    return $self->_invoke('complete_child', $frame_id, $child_link);
}

sub _complete_exception {
    my ($self, $frame_id) = @_;
    return $self->_invoke('complete_exception', $frame_id);
}

sub DESTROY {
    my ($self) = @_;
    delete $RECORDER_STATE{refaddr($self)};
    return;
}

1;

__END__

=head1 NAME

PAGI::Routing::Trace::Recorder - Internal routing compiler writer

=head1 DESCRIPTION

This class is an unsupported internal capability object used only by the
first-party routing compiler. It is never stored in request scope. Its private
methods and representation are not an application extension API.

=cut
