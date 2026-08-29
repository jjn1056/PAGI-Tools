package PAGI::Response::Problem;

use strict;
use warnings;

use Carp qw(croak);
use Exporter qw(import);
use Scalar::Util qw(blessed);
use parent 'PAGI::Response::JSON';

=encoding UTF-8

=head1 NAME

PAGI::Response::Problem - buffered RFC 9457 problem response

=head1 SYNOPSIS

    use PAGI::Response::Problem qw(problem_response);
    my $response = PAGI::Response::Problem->new({
        type   => '/problems/invalid-input',
        title  => 'Invalid input',
        status => 422,
    });
    my $same = problem_response({ title => 'Conflict', status => 409 });

=head1 DESCRIPTION

Validates an unblessed RFC 9457 problem hashref before buffering it as UTF-8
JSON with C<application/problem+json>. C<type>, C<title>, C<status>, C<detail>,
and C<instance> are optional and validated when present; other JSON-encodable
members are extensions. Missing C<type> has the effective RFC value
C<about:blank> without inserting that member. A document C<status> supplies
the HTTP status unless an equal constructor status is given; mismatches croak.
When the document contains C<status>, that agreement remains response-owned:
an incompatible status mutation is rejected, and snapshots validate the
agreement again before any event can be emitted.

=cut

our @EXPORT_OK = qw(problem_response);

sub problem_response {
    return PAGI::Response::Problem->new(@_);
}

sub new {
    my ($class, $problem, @pairs) = @_;
    croak 'Problem response requires an unblessed hashref'
        unless ref($problem) eq 'HASH' && !blessed($problem);

    my $options = PAGI::Response::_parse_options(@pairs);
    _validate_problem($problem);

    if (exists $problem->{status}) {
        my $document_status = 0 + $problem->{status};
        if (exists $options->{status}) {
            croak 'Problem document and HTTP statuses must agree'
                unless $document_status == 0 + $options->{status};
        } else {
            push @pairs, status => $document_status;
        }
    }

    my $self = $class->SUPER::new($problem, @pairs);
    $self->{_problem_document_status} = 0 + $problem->{status}
        if exists $problem->{status};
    return $self;
}

sub default_content_type { 'application/problem+json' }

sub status {
    my ($self, $status) = @_;
    return $self->SUPER::status if @_ == 1;

    PAGI::Response::_validate_status($status);
    croak 'Problem document and HTTP statuses must agree'
        if exists($self->{_problem_document_status})
            && 0 + $status != $self->{_problem_document_status};
    return $self->SUPER::status($status);
}

sub _snapshot {
    my ($self) = @_;
    $self->_validate_problem_status_invariant;
    my $copy = $self->SUPER::_snapshot;
    $copy->{_problem_document_status} = $self->{_problem_document_status}
        if exists $self->{_problem_document_status};
    return $copy;
}

sub _validate_problem_status_invariant {
    my ($self) = @_;
    return unless exists $self->{_problem_document_status};
    croak 'Problem document and HTTP statuses must agree'
        unless $self->status == $self->{_problem_document_status};
    return;
}

sub _validate_problem {
    my ($problem) = @_;

    for my $member (qw(type instance)) {
        next unless exists $problem->{$member};
        PAGI::Response::_validate_uri_reference("Problem $member", $problem->{$member});
    }
    for my $member (qw(title detail)) {
        next unless exists $problem->{$member};
        croak "Problem $member must be a string scalar"
            unless defined($problem->{$member}) && !ref($problem->{$member});
    }
    return unless exists $problem->{status};
    my $status = $problem->{status};
    croak 'Problem status must be an integer HTTP status from 100 through 599'
        unless defined($status) && !ref($status) && $status =~ /\A\d+\z/;
    croak 'Problem status must be an integer HTTP status from 100 through 599'
        unless $status >= 100 && $status <= 599;
    return;
}

1;
