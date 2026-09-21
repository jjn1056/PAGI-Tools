package PAGI::Utils::Headers;

use strict;
use warnings;
use Carp qw(croak);
use Exporter qw(import);
use MIME::Base64 qw(decode_base64);

our @EXPORT = ();
our @EXPORT_OK = qw(
    parse_authorization_bearer
    parse_authorization_basic
    www_authenticate
);

my $HTTP_TOKEN = qr/[!#\$%&'*+\-.\^_`|~0-9A-Za-z]+/;
my $BEARER_TOKEN = qr/[A-Za-z0-9\-._~+\/]+={0,}/;
my $BASE64 = qr/(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?/;

sub parse_authorization_bearer {
    my ($value, @args) = @_;
    my $raise = _parser_options('parse_authorization_bearer', @args);
    my ($state, $rest) = _authorization_scheme(
        'parse_authorization_bearer', $value, 'Bearer');
    return undef if $state eq 'missing' || $state eq 'other';
    return _malformed('parse_authorization_bearer', $raise) if $state eq 'malformed';

    return $1 if $rest =~ /\A +($BEARER_TOKEN)[\x20\x09]*\z/;
    return _malformed('parse_authorization_bearer', $raise);
}

sub parse_authorization_basic {
    my ($value, @args) = @_;
    my $raise = _parser_options('parse_authorization_basic', @args);
    my ($state, $rest) = _authorization_scheme(
        'parse_authorization_basic', $value, 'Basic');
    return (undef, undef) if $state eq 'missing' || $state eq 'other';
    if ($state eq 'malformed') {
        _malformed('parse_authorization_basic', $raise);
        return (undef, undef);
    }

    unless ($rest =~ /\A +(?=[A-Za-z0-9+\/])($BASE64)[\x20\x09]*\z/) {
        _malformed('parse_authorization_basic', $raise);
        return (undef, undef);
    }
    my $decoded = decode_base64($1);
    if ($decoded !~ /:/ || $decoded =~ /[\x00-\x1f\x7f]/) {
        _malformed('parse_authorization_basic', $raise);
        return (undef, undef);
    }
    return split /:/, $decoded, 2;
}

sub www_authenticate {
    croak 'PAGI::Utils::Headers www_authenticate scheme is required' unless @_;
    my ($scheme, @args) = @_;
    croak 'PAGI::Utils::Headers www_authenticate scheme must be an HTTP token'
        unless defined($scheme) && !ref($scheme) && $scheme =~ /\A$HTTP_TOKEN\z/;
    croak 'PAGI::Utils::Headers www_authenticate parameters must be name/value pairs'
        if @args % 2;

    my (%seen, @serialized);
    while (@args) {
        my ($name, $value) = splice @args, 0, 2;
        croak 'PAGI::Utils::Headers www_authenticate parameter name must be an HTTP token'
            unless defined($name) && !ref($name) && $name =~ /\A$HTTP_TOKEN\z/;
        croak "PAGI::Utils::Headers www_authenticate duplicate parameter '$name'"
            if $seen{_ascii_fold($name)}++;
        croak "PAGI::Utils::Headers www_authenticate value for '$name' must be a defined scalar"
            unless defined($value) && !ref($value);
        croak "PAGI::Utils::Headers www_authenticate value for '$name' must be an HTTP quoted-string byte value"
            unless $value =~ /\A[\x09\x20-\x7e\x80-\xff]*\z/;
        $value =~ s/([\\"])/\\$1/g;
        push @serialized, $name . '="' . $value . '"';
    }
    return @serialized ? $scheme . ' ' . join(', ', @serialized) : $scheme;
}

sub _parser_options {
    my ($operation, @args) = @_;
    croak "PAGI::Utils::Headers $operation options must be key/value pairs"
        if @args % 2;
    my %opts;
    while (@args) {
        my ($name, $value) = splice @args, 0, 2;
        croak "PAGI::Utils::Headers $operation option names must be defined scalars"
            unless defined($name) && !ref($name);
        croak "PAGI::Utils::Headers $operation has unknown option '$name'"
            unless $name eq 'raise_on_error';
        croak "PAGI::Utils::Headers $operation has duplicate option '$name'"
            if exists $opts{$name};
        $opts{$name} = $value;
    }
    return $opts{raise_on_error} ? 1 : 0;
}

sub _authorization_scheme {
    my ($operation, $value, $supported) = @_;
    return ('missing', undef) unless defined $value;
    croak "PAGI::Utils::Headers $operation Authorization value must be a scalar"
        if ref($value);

    $value =~ s/\A[\x20\x09]*//;
    $value =~ s/[\x20\x09]*\z//;
    return ('malformed', undef) unless length $value;
    return ('malformed', undef) unless $value =~ /\A($HTTP_TOKEN)(.*)\z/s;
    my ($scheme, $rest) = ($1, $2);
    return ('other', undef) unless _ascii_fold($scheme) eq _ascii_fold($supported);
    return ('supported', $rest);
}

sub _malformed {
    my ($operation, $raise) = @_;
    croak "PAGI::Utils::Headers $operation received a malformed Authorization credential"
        if $raise;
    return undef;
}

sub _ascii_fold {
    my ($value) = @_;
    $value =~ tr/A-Z/a-z/;
    return $value;
}

1;

__END__

=head1 NAME

PAGI::Utils::Headers - synchronous parsers and formatters for HTTP header values

=head1 SYNOPSIS

  use PAGI::Utils::Headers qw(
      parse_authorization_bearer parse_authorization_basic www_authenticate
  );

  my $token = parse_authorization_bearer($value, raise_on_error => 1);
  my ($user, $password) = parse_authorization_basic($value);
  my $challenge = www_authenticate('Bearer', realm => 'api');

=head1 DESCRIPTION

These independent functions parse or format one header value. They do not read
or write a request, verify credentials, decode character encodings, or emit a
response. Nothing is exported by default.

=head1 FUNCTIONS

=head2 parse_authorization_bearer($value, %opts)

Returns an opaque RFC 6750 Bearer token, or C<undef> for missing input, another
identifiable authentication scheme, or malformed input. C<raise_on_error =E<gt>
1> instead raises for malformed supported credentials; it does not make a
missing value or another scheme an error. The sole option is
C<raise_on_error>; unknown or duplicate options are programming errors.

Only ASCII grammar is recognized. Surrounding optional whitespace is SP or
HTAB, and the scheme/token separator is one or more SP. The function neither
verifies nor decodes the token.

=head2 parse_authorization_basic($value, %opts)

Returns C<(username, password)> in list context after validating conventional
padded Base64 and splitting decoded bytes at the first colon. Empty components
and bytes above ASCII are values. It returns C<(undef, undef)> for missing,
another identifiable scheme, or malformed input; C<raise_on_error =E<gt> 1>
raises for malformed supported credentials. The option and syntax rules are the
same as L</parse_authorization_bearer($value, %opts)>.

No Base64 repair, credential verification, or character decoding is performed.
Decoded controls and a missing colon are rejected.

=head2 www_authenticate($scheme, name =E<gt> $value, ...)

Formats one plain C<WWW-Authenticate> challenge. Scheme and parameter names
must be HTTP tokens; names are unique case-insensitively. Values are quoted and
quotes/backslashes are escaped. The function preserves pair order and always
quotes parameters; it does not serialize scheme-specific forms such as unquoted
Digest parameters.

=cut
