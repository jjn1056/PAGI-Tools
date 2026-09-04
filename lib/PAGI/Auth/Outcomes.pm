package PAGI::Auth::Outcomes;

use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(blessed);

use PAGI::Auth::Challenge ();
use PAGI::Pages ();

my %OUTCOME_OPTION = map { $_ => 1 } qw(
    as detail type title instance extensions headers cache_control challenges
);

sub new {
    my ($class, %args) = @_;

    for my $key (keys %args) {
        croak "PAGI::Auth::Outcomes has unknown option '$key'"
            unless $key eq 'pages';
    }

    my $pages = exists $args{pages} ? $args{pages} : PAGI::Pages->new;
    croak 'PAGI::Auth::Outcomes pages must be a PAGI::Pages instance'
        unless blessed($pages) && $pages->isa('PAGI::Pages');

    return bless { pages => $pages }, $class;
}

sub challenge {
    my ($self, @args) = _invocation(@_);
    my ($opts, $values) = $self->_normalize_outcome('challenge', @args);
    $self->_validate_caller_headers($opts);
    $opts->{challenge} = [map { $_->header_value } @$values];
    return $self->{pages}->unauthorized(%$opts);
}

sub forbid {
    my ($self, @args) = _invocation(@_);
    my ($opts, $values) = $self->_normalize_outcome('forbid', @args);
    $self->_validate_caller_headers($opts);

    my @headers = @{$opts->{headers} || []};
    push @headers, map { ('WWW-Authenticate' => $_->header_value) } @$values;
    $opts->{headers} = \@headers if @headers;
    return $self->{pages}->forbidden(%$opts);
}

sub _invocation {
    my ($proto, @args) = @_;

    if (blessed($proto)) {
        croak 'PAGI::Auth::Outcomes invocant must be an Outcomes class or instance'
            unless $proto->isa('PAGI::Auth::Outcomes');
        return ($proto, @args);
    }

    croak 'PAGI::Auth::Outcomes invocant must be an Outcomes class or instance'
        if ref($proto);
    croak 'PAGI::Auth::Outcomes invocant must be an Outcomes class or instance'
        unless defined($proto) && $proto->isa('PAGI::Auth::Outcomes');
    return ($proto->new, @args);
}

sub _normalize_outcome {
    my ($self, $outcome, @args) = @_;
    croak "PAGI::Auth::Outcomes $outcome options must be key/value pairs"
        if @args % 2;

    my %opts;
    while (@args) {
        my ($key, $value) = splice(@args, 0, 2);
        croak "PAGI::Auth::Outcomes $outcome option names must be nonempty scalars"
            unless defined($key) && !ref($key) && length($key);
        croak "PAGI::Auth::Outcomes $outcome has unknown option '$key'"
            unless $OUTCOME_OPTION{$key};
        $opts{$key} = $value;
    }

    my $has_challenges = exists $opts{challenges};
    my $supplied = delete $opts{challenges};
    croak 'PAGI::Auth::Outcomes challenge challenges is required'
        if $outcome eq 'challenge' && !$has_challenges;

    my @values;
    if ($has_challenges) {
        if (blessed($supplied)
                && $supplied->isa('PAGI::Auth::Challenge')) {
            @values = ($supplied);
        }
        elsif (ref($supplied) eq 'ARRAY' && !blessed($supplied)) {
            croak "PAGI::Auth::Outcomes $outcome challenges must be nonempty"
                unless @$supplied;
            @values = @$supplied;
        }
        else {
            @values = ($supplied);
        }
    }

    for my $index (0 .. $#values) {
        my $value = $values[$index];
        croak "PAGI::Auth::Outcomes $outcome challenges[$index] must be a "
            . 'PAGI::Auth::Challenge'
            unless blessed($value)
                && $value->isa('PAGI::Auth::Challenge');
        _validate_bearer_outcome($outcome, $value);
    }

    return (\%opts, \@values);
}

sub _validate_bearer_outcome {
    my ($outcome, $value) = @_;
    return unless $value->_kind eq 'bearer';

    my $error = $value->_error;
    if ($outcome eq 'challenge') {
        return unless defined $error;
        return if $error eq 'invalid_token'
            || $error eq 'insufficient_user_authentication';
        croak 'PAGI::Auth challenge cannot use Bearer invalid_request; '
            . 'use an explicit 400'
            if $error eq 'invalid_request';
        croak 'PAGI::Auth challenge cannot use Bearer insufficient_scope; '
            . 'use forbid'
            if $error eq 'insufficient_scope';
        return;
    }

    return if defined($error) && $error eq 'insufficient_scope';
    return if defined($error)
        && $error ne 'invalid_token'
        && $error ne 'invalid_request'
        && $error ne 'insufficient_user_authentication';

    croak 'PAGI::Auth forbid Bearer challenge requires '
        . 'error=insufficient_scope';
}

sub _validate_caller_headers {
    my ($self, $opts) = @_;
    return unless exists $opts->{headers};

    # Preflight the untouched caller options through Pages. This keeps Pages
    # authoritative for presentation and raw-header validation before Auth
    # appends its own WWW-Authenticate fields for a 403 response.
    $self->{pages}->forbidden(%$opts);
    for (my $index = 0; $index < @{$opts->{headers}}; $index += 2) {
        my $name = $opts->{headers}[$index];
        croak 'PAGI::Auth::Outcomes caller WWW-Authenticate is Auth-owned'
            if lc($name) eq 'www-authenticate';
    }
    return;
}

1;
