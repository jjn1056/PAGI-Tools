package PAGI::Response::Redirect;

use strict;
use warnings;

use Carp qw(croak);
use Encode qw(encode FB_CROAK);
use Exporter qw(import);
use parent 'PAGI::Response';

=encoding UTF-8

=head1 NAME

PAGI::Response::Redirect - buffered HTTP redirect response

=head1 SYNOPSIS

    use PAGI::Response::Redirect qw(redirect_response);
    my $response = PAGI::Response::Redirect->new('/next', status => 303);
    my $same = redirect_response('/next', status => 303);

=head1 DESCRIPTION

Buffers a small escaped HTML document and owns its validated URI-reference
Location. Status defaults to 302 and must be 301, 302, 303, 307, or 308.
Common flat C<headers> and C<content_type> are accepted, but callers cannot
compete with the response-owned Location field. The chosen status and exact
single Location remain tied to the buffered HTML body. Mutations that would
stale those semantics are rejected directly or, for the mutable header
container, while deriving the invocation's delivery values before emission.

=cut

our @EXPORT_OK = qw(redirect_response);

my %REDIRECT_STATUS = map { $_ => 1 } qw(301 302 303 307 308);
my %REDIRECT_TITLE = (
    301 => 'Moved Permanently',
    302 => 'Found',
    303 => 'See Other',
    307 => 'Temporary Redirect',
    308 => 'Permanent Redirect',
);

sub redirect_response {
    return PAGI::Response::Redirect->new(@_);
}

sub new {
    my ($class, $location, @pairs) = @_;
    $location = PAGI::Response::_validate_uri_reference('Redirect location', $location);
    $location = encode('UTF-8', $location, FB_CROAK);
    my $options = PAGI::Response::_parse_options(@pairs);
    my $status = exists($options->{status}) ? $options->{status} : 302;
    $status = _validate_redirect_status($status);
    _reject_location_header($options->{headers}) if exists $options->{headers};

    push @pairs, status => 302 unless exists $options->{status};
    my $title = $REDIRECT_TITLE{0 + $status};
    my $escaped = _escape_html($location);
    my $body = '<!doctype html><html><head><title>' . $title
        . '</title></head><body><p>Redirecting to <a href="' . $escaped
        . '">' . $escaped . '</a>.</p></body></html>';
    my $self = $class->SUPER::new($body, @pairs);
    PAGI::Response::header($self, 'Location', $location);
    $self->{_redirect_status} = $status;
    $self->{_redirect_location} = $location;
    return $self;
}

sub default_content_type { 'text/html; charset=utf-8' }

sub status {
    my ($self, $status) = @_;
    return $self->SUPER::status if @_ == 1;
    $status = _validate_redirect_status($status);
    croak 'Redirect status is response-owned'
        if exists($self->{_redirect_status})
            && $status != $self->{_redirect_status};
    return $self->SUPER::status($status);
}

sub header {
    my ($self, $name, $value) = @_;
    return $self->SUPER::header($name) if @_ == 2;
    croak 'Redirect Location is response-owned'
        if defined($name) && !ref($name) && lc($name) eq 'location';
    return $self->SUPER::header($name, $value);
}

sub remove_header {
    my ($self, $name) = @_;
    croak 'Redirect Location is response-owned'
        if defined($name) && !ref($name) && lc($name) eq 'location';
    return $self->SUPER::remove_header($name);
}

sub _emission_plan {
    my ($self) = @_;
    $self->_validate_redirect_invariants;
    return $self->SUPER::_emission_plan;
}

sub _validate_redirect_invariants {
    my ($self) = @_;
    croak 'Redirect status is response-owned'
        unless $self->status == $self->{_redirect_status};

    my @locations = $self->{_headers}->get_all('Location');
    croak 'Redirect requires exactly one canonical Location'
        unless @locations == 1
            && $locations[0] eq $self->{_redirect_location};
    return;
}

sub _validate_redirect_status {
    my ($status) = @_;
    croak 'Redirect status must be one of 301, 302, 303, 307, or 308'
        unless defined($status) && !ref($status) && $status =~ /\A\d+\z/
            && $REDIRECT_STATUS{0 + $status};
    return 0 + $status;
}

sub _reject_location_header {
    my ($headers) = @_;
    return unless ref($headers) eq 'ARRAY' && @$headers % 2 == 0;
    for (my $index = 0; $index < @$headers; $index += 2) {
        my $name = $headers->[$index];
        croak 'Redirect Location is response-owned'
            if defined($name) && !ref($name) && lc($name) eq 'location';
    }
    return;
}

sub _escape_html {
    my ($value) = @_;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    $value =~ s/'/&#39;/g;
    return $value;
}

1;
