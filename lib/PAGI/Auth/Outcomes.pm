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

=head1 NAME

PAGI::Auth::Outcomes - configurable authentication outcome factories

=head1 SYNOPSIS

  my $auth = PAGI::Auth::Outcomes->new(
      pages => MyApp::Pages->new,
  );
  my $app = $auth->challenge(
      challenges => [PAGI::Auth::bearer(realm => 'api')],
  );

=head1 CONSTRUCTION

C<new> accepts only C<pages>, which must be a L<PAGI::Pages> instance (a
subclass is allowed). The default is a fresh C<PAGI::Pages> instance. This is
the supported hook for application-specific synchronous rendering and
presentation.

=head1 METHODS

=head2 challenge

Constructs a reusable 401 Pages application. C<challenges> is required and is
one L<PAGI::Auth::Challenge> or a nonempty arrayref of them.

=head2 forbid

Constructs a reusable 403 Pages application. C<challenges> is optional; when
present it accepts the same shapes. A Bearer challenge on 403 must use
C<error=insufficient_scope>.

Both methods also accept C<as>, C<detail>, C<type>, C<title>, C<instance>,
C<extensions>, C<headers>, and C<cache_control>. Unknown options croak. Auth
reserves C<WWW-Authenticate>; other caller headers are validated by
Pages before Auth appends one separate field line per challenge.

The methods may also be called on the class, which creates a default instance.
They do not cache applications or mutate identities, scopes, challenges, Pages
instances, or caller data.

=head1 MATERIALIZATION

The returned L<PAGI::Pages::Application> can be invoked repeatedly. Its
C<response_for> method synchronously creates a concrete local
L<PAGI::Response> for a Request, WebSocket, SSE, or raw scope hash. It sends no
events. The protocol helper remains responsible for emission:

  my $failure = $auth->challenge(
      challenges => [PAGI::Auth::bearer(realm => 'events')],
      as => 'text',
  );
  return await $sse->decline($failure->response_for($sse));

=head1 SEE ALSO

L<PAGI::Auth>, L<PAGI::Pages>, L<PAGI::Pages::Application>

=cut
