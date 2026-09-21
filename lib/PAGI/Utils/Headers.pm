package PAGI::Utils::Headers;

use strict;
use warnings;
use Carp qw(croak);
use Encode qw(encode);
use Exporter qw(import);
use MIME::Base64 qw(decode_base64);

our @EXPORT = ();
our @EXPORT_OK = qw(
    parse_authorization_bearer
    parse_authorization_basic
    www_authenticate
    parse_header_parameters
    format_header_parameters
    quote_header_value
    content_disposition
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
        push @serialized, $name . '=' . _quote_header_value($value,
            "www_authenticate value for '$name'");
    }
    return @serialized ? $scheme . ' ' . join(', ', @serialized) : $scheme;
}

sub parse_header_parameters {
    my ($value, @args) = @_;
    my $raise = _parser_options('parse_header_parameters', @args);
    return undef unless defined $value;
    croak 'PAGI::Utils::Headers parse_header_parameters value must be a scalar'
        if ref($value);

    pos($value) = 0;
    return _malformed_parameters('parse_header_parameters', $raise)
        unless $value =~ /\G[\x20\x09]*([^;]*)/gc;
    my $leading = $1;
    $leading =~ s/[\x20\x09]*\z//;
    return _malformed_parameters('parse_header_parameters', $raise)
        unless length($leading) && $leading =~ /\A[\x20-\x2b\x2d-\x3a\x3c-\x7e\x80-\xff]+\z/;

    my @parameters;
    while (pos($value) < length($value)) {
        return _malformed_parameters('parse_header_parameters', $raise)
            unless $value =~ /\G;[\x20\x09]*/gc;
        next if pos($value) == length($value) || substr($value, pos($value), 1) eq ';';
        return _malformed_parameters('parse_header_parameters', $raise)
            unless $value =~ /\G($HTTP_TOKEN)[\x20\x09]*=[\x20\x09]*/gc;
        my $name = _ascii_fold($1);
        my $parameter;
        if ($value =~ /\G"/gc) {
            my $closed;
            $parameter = '';
            while (pos($value) < length($value)) {
                if ($value =~ /\G"/gc) { $closed = 1; last }
                if ($value =~ /\G\\([\x09\x20-\x7e\x80-\xff])/gc) {
                    $parameter .= $1;
                    next;
                }
                if ($value =~ /\G([\x09\x20-\x21\x23-\x5b\x5d-\x7e\x80-\xff]+)/gc) {
                    $parameter .= $1;
                    next;
                }
                last;
            }
            return _malformed_parameters('parse_header_parameters', $raise) unless $closed;
        }
        elsif ($value =~ /\G($HTTP_TOKEN)/gc) {
            $parameter = $1;
        }
        else {
            return _malformed_parameters('parse_header_parameters', $raise);
        }
        $value =~ /\G[\x20\x09]*/gc;
        return _malformed_parameters('parse_header_parameters', $raise)
            if pos($value) < length($value) && substr($value, pos($value), 1) ne ';';
        push @parameters, $name, $parameter;
    }
    return { value => $leading, parameters => \@parameters };
}

sub format_header_parameters {
    croak 'PAGI::Utils::Headers format_header_parameters leading value is required' unless @_;
    my ($leading, @pairs) = @_;
    croak 'PAGI::Utils::Headers format_header_parameters leading value must be a safe byte string'
        unless defined($leading) && !ref($leading) && length($leading)
            && $leading =~ /\A[\x20-\x2b\x2d-\x3a\x3c-\x7e\x80-\xff]+\z/
            && $leading =~ /[^\x20]/;
    croak 'PAGI::Utils::Headers format_header_parameters parameters must be name/value pairs'
        if @pairs % 2;
    my @formatted;
    while (@pairs) {
        my ($name, $value) = splice @pairs, 0, 2;
        croak 'PAGI::Utils::Headers format_header_parameters parameter name must be an HTTP token'
            unless defined($name) && !ref($name) && $name =~ /\A$HTTP_TOKEN\z/;
        croak 'PAGI::Utils::Headers format_header_parameters parameter value must be a defined scalar'
            unless defined($value) && !ref($value);
        push @formatted, $name . '=' . ($value =~ /\A$HTTP_TOKEN\z/
            ? $value : _quote_header_value($value, 'format_header_parameters value'));
    }
    return join('; ', $leading, @formatted);
}

sub quote_header_value {
    croak 'PAGI::Utils::Headers quote_header_value requires one value' unless @_ == 1;
    return _quote_header_value($_[0], 'quote_header_value');
}

sub content_disposition {
    croak 'PAGI::Utils::Headers content_disposition disposition is required' unless @_;
    my ($disposition, @pairs) = @_;
    croak 'PAGI::Utils::Headers content_disposition disposition must be an HTTP token'
        unless defined($disposition) && !ref($disposition)
            && $disposition =~ /\A$HTTP_TOKEN\z/;
    croak 'PAGI::Utils::Headers content_disposition parameters must be name/value pairs'
        if @pairs % 2;

    my (%seen, @formatted);
    my $explicit_extended = 0;
    for (my $i = 0; $i < @pairs; $i += 2) {
        my ($name, $value) = @pairs[$i, $i + 1];
        croak 'PAGI::Utils::Headers content_disposition parameter name must be an HTTP token'
            unless defined($name) && !ref($name) && $name =~ /\A$HTTP_TOKEN\z/;
        my $folded = _ascii_fold($name);
        croak "PAGI::Utils::Headers content_disposition duplicate parameter '$name'"
            if $seen{$folded}++;
        croak "PAGI::Utils::Headers content_disposition value for '$name' must be a defined scalar"
            unless defined($value) && !ref($value);
        $explicit_extended = 1 if $folded eq 'filename*';
    }

    while (@pairs) {
        my ($name, $value) = splice @pairs, 0, 2;
        my $folded = _ascii_fold($name);
        if ($folded eq 'filename') {
            croak 'PAGI::Utils::Headers content_disposition filename must not contain controls'
                if $value =~ /[\x00-\x1f\x7f]/;
            if ($value =~ /[^\x00-\x7f]/) {
                croak 'PAGI::Utils::Headers content_disposition filename* conflicts with generated value'
                    if $explicit_extended;
                my $octets = eval { encode('UTF-8', $value, Encode::FB_CROAK | Encode::LEAVE_SRC) };
                croak 'PAGI::Utils::Headers content_disposition filename contains an invalid character'
                    unless defined $octets;
                $octets =~ s/([^A-Za-z0-9!#\$&+\-.\^_`|~])/sprintf('%%%02X', ord($1))/ge;
                push @formatted, "filename*=UTF-8''$octets";
            }
            else {
                push @formatted, $name . '=' . _quote_header_value($value,
                    'content_disposition filename');
            }
        }
        elsif ($folded eq 'filename*') {
            croak 'PAGI::Utils::Headers content_disposition filename* must be a valid ASCII extended value'
                unless $value =~ /\A[A-Za-z0-9!#\$%&+\-.\^_`|~]+'(?:[A-Za-z]{1,8}(?:-[A-Za-z0-9]{1,8})*)?'(?:[A-Za-z0-9!#\$&+\-.\^_`|~]|%[0-9A-Fa-f]{2})*\z/;
            push @formatted, "$name=$value";
        }
        else {
            push @formatted, $name . '=' . ($value =~ /\A$HTTP_TOKEN\z/
                ? $value : _quote_header_value($value,
                    "content_disposition value for '$name'"));
        }
    }
    my $result = join('; ', $disposition, @formatted);
    croak 'PAGI::Utils::Headers content_disposition result must be a byte string'
        unless utf8::downgrade($result, 1);
    return $result;
}

sub _quote_header_value {
    my ($value, $operation) = @_;
    croak "PAGI::Utils::Headers $operation must be an HTTP quoted-string byte value"
        unless defined($value) && !ref($value) && $value =~ /\A[\x09\x20-\x7e\x80-\xff]*\z/;
    $value =~ s/([\\"])/\\$1/g;
    return '"' . $value . '"';
}

sub _malformed_parameters {
    my ($operation, $raise) = @_;
    croak "PAGI::Utils::Headers $operation received a malformed parameterized value" if $raise;
    return undef;
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

=encoding UTF-8

=head1 NAME

PAGI::Utils::Headers - synchronous parsers and formatters for HTTP header values

=head1 SYNOPSIS

  use PAGI::Utils::Headers qw(
      parse_authorization_bearer parse_authorization_basic www_authenticate
      parse_header_parameters format_header_parameters quote_header_value
      content_disposition
  );

  my $token = parse_authorization_bearer($value, raise_on_error => 1);
  my ($user, $password) = parse_authorization_basic($value);
  my $challenge = www_authenticate('Bearer', realm => 'api');
  my $parsed = parse_header_parameters('attachment; filename="report; Q1.txt"');
  # { value => 'attachment', parameters => [filename => 'report; Q1.txt'] }
  my $field = format_header_parameters('attachment', filename => 'report; Q1.txt');
  my $quoted = quote_header_value('report.txt');
  my $download = content_disposition('attachment', filename => 'résumé.pdf');

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

=head2 parse_header_parameters($value, %opts)

Parses one parameterized field value and returns C<< { value =E<gt> $leading,
parameters =E<gt> \@pairs } >>. The parameter array holds alternating,
ASCII-lowercased names and raw value bytes in input order. It retains duplicate
names and quoted empty values. Quoted semicolons and escaped quotes/backslashes
are data; extended parameters such as C<filename*> are not percent-decoded.
Empty semicolon slots are ignored.

Missing input returns C<undef>. Malformed input, including a missing leading
value, missing equals or value, unterminated quote, invalid byte, or leftover
syntax, returns C<undef> by default. C<raise_on_error =E<gt> 1> raises for
malformed input. Unknown and duplicate options are programming errors. The
result is ordinary detached data: changing it does not change a stored header.

=head2 format_header_parameters($leading, name =E<gt> $value, ...)

Formats an already-selected leading value with ordered parameter pairs. For
example, C<< format_header_parameters('attachment', filename =E<gt>
'report; Q1.txt') >> returns C<< attachment; filename="report; Q1.txt" >>.
Token values remain unquoted; other supported byte values are quoted and
escaped. Repeated names are retained. The leading value must be nonempty and
cannot contain comma, semicolon, control bytes, or wide characters. Invalid
names, values, or pair shapes raise a programming error.

=head2 quote_header_value($bytes)

Always returns an HTTP quoted-string, escaping quotes and backslashes. It
accepts HTTP quoted-string bytes, including HTAB and bytes above ASCII, but
rejects other controls, wide characters, references, and undefined values.
It does not encode characters or quote other grammars such as ETags.

=head2 content_disposition($disposition, name =E<gt> $value, ...)

Formats an HTTP Content-Disposition byte value. The disposition and parameter
names must be HTTP tokens, and parameter names must be unique without regard
to ASCII case. Pair order is preserved. Ordinary parameters use token syntax
where possible and shared quoted-string escaping otherwise.

The C<filename> value is a Perl character string. ASCII filenames always use
a quoted C<filename> parameter. A filename containing non-ASCII characters
instead uses C<filename*> with UTF-8 octets percent-encoded as an RFC 8187
extended value; no ASCII fallback is invented. Callers holding encoded text
must decode it before calling this function. Control characters and invalid
Unicode characters in filenames are rejected.

An explicit C<filename*> is an already formatted ASCII extended value. Its
charset, optional language, percent escapes, and value syntax are checked,
then it is emitted unchanged and without quotes. It may accompany an ASCII
C<filename> fallback, but cannot accompany a non-ASCII C<filename> that would
generate another C<filename*>. Invalid arguments raise an exception.

=cut
