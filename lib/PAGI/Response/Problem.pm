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

    my $response = PAGI::Response::Problem->new({
        type   => '/problems/invalid-input',
        title  => 'Invalid input',
        status => 422,
    });

=head1 DESCRIPTION

Validates an RFC 9457 problem hashref before rendering it as UTF-8 JSON.  The
optional C<type>, C<title>, C<status>, C<detail>, and C<instance> members are
validated when present; other JSON-encodable members are extensions.

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

    return $class->SUPER::new($problem, @pairs);
}

sub default_content_type { 'application/problem+json' }

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
