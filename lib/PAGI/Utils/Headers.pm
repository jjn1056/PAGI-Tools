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
    parse_header_tokens
    merge_vary
    parse_etag
    format_etag
    parse_etag_list
    etag_matches
);

my $HTTP_TOKEN = qr/[!#\$%&'*+\-.\^_`|~0-9A-Za-z]+/;
my $BEARER_TOKEN = qr/[A-Za-z0-9\-._~+\/]+={0,}/;
my $BASE64 = qr/(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?/;
my $ETAG_OPAQUE = qr/[\x21\x23-\x7e\x80-\xff]*/;
my $ETAG_WIRE = qr/(?:W\/)?"$ETAG_OPAQUE"/;

sub parse_etag {
    my ($value, @args) = @_;
    my $raise = _parser_options('parse_etag', @args);
    return undef unless defined $value;
    croak 'PAGI::Utils::Headers parse_etag value must be a scalar' if ref($value);
    return { value => $2, weak => defined($1) ? 1 : 0 }
        if $value =~ /\A[\x20\x09]*(W\/)?"($ETAG_OPAQUE)"[\x20\x09]*\z/;
    return _malformed_etag('parse_etag', $raise);
}

sub format_etag {
    croak 'PAGI::Utils::Headers format_etag opaque value is required' unless @_;
    my ($opaque, @args) = @_;
    my $weak = _etag_weak_option('format_etag', @args);
    croak 'PAGI::Utils::Headers format_etag opaque value must be valid HTTP bytes'
        unless defined($opaque) && !ref($opaque) && $opaque =~ /\A$ETAG_OPAQUE\z/;
    return ($weak ? 'W/' : '') . '"' . $opaque . '"';
}

sub parse_etag_list {
    my ($values, @args) = @_;
    my $raise = _parser_options('parse_etag_list', @args);
    croak 'PAGI::Utils::Headers parse_etag_list requires an arrayref of field values'
        unless ref($values) eq 'ARRAY';
    return undef unless @$values;
    for my $value (@$values) {
        croak 'PAGI::Utils::Headers parse_etag_list field values must be defined scalars'
            unless defined($value) && !ref($value);
    }

    my (@tags, $wildcards);
    $wildcards = 0;
    for my $field_value (@$values) {
        my $value = $field_value;
        pos($value) = 0;
        while (pos($value) < length($value)) {
            $value =~ /\G[\x20\x09]*/gc;
            last if pos($value) == length($value);
            if ($value =~ /\G,/gc) { next }
            if ($value =~ /\G\*/gc) {
                $wildcards++;
            }
            elsif ($value =~ /\G($ETAG_WIRE)/gc) {
                push @tags, parse_etag($1);
            }
            else {
                return _malformed_etag('parse_etag_list', $raise);
            }
            $value =~ /\G[\x20\x09]*/gc;
            next if pos($value) == length($value);
            return _malformed_etag('parse_etag_list', $raise)
                unless $value =~ /\G,/gc;
        }
    }
    return _malformed_etag('parse_etag_list', $raise)
        if $wildcards && (@$values != 1 || $values->[0] !~ /\A[\x20\x09]*\*[\x20\x09]*\z/);
    return { any => $wildcards ? 1 : 0, tags => \@tags };
}

sub etag_matches {
    my ($condition, $current_wire, @args) = @_;
    my $weak = _etag_weak_option('etag_matches', @args);
    croak 'PAGI::Utils::Headers etag_matches current ETag must be a valid wire entity-tag'
        unless defined($current_wire) && !ref($current_wire);
    my $current = parse_etag($current_wire);
    croak 'PAGI::Utils::Headers etag_matches current ETag must be a valid wire entity-tag'
        unless defined $current;
    return 0 unless defined $condition;
    _validate_etag_condition($condition);
    return 1 if $condition->{any};
    for my $candidate (@{$condition->{tags}}) {
        next if !$weak && ($candidate->{weak} || $current->{weak});
        return 1 if $candidate->{value} eq $current->{value};
    }
    return 0;
}

sub _etag_weak_option {
    my ($operation, @args) = @_;
    croak "PAGI::Utils::Headers $operation options must be key/value pairs" if @args % 2;
    my %opts;
    while (@args) {
        my ($name, $value) = splice @args, 0, 2;
        croak "PAGI::Utils::Headers $operation option names must be defined scalars"
            unless defined($name) && !ref($name);
        croak "PAGI::Utils::Headers $operation has unknown option '$name'"
            unless $name eq 'weak';
        croak "PAGI::Utils::Headers $operation has duplicate option '$name'"
            if exists $opts{$name};
        croak "PAGI::Utils::Headers $operation weak option must be a boolean scalar"
            if defined($value) && ref($value);
        $opts{$name} = $value;
    }
    return $opts{weak} ? 1 : 0;
}

sub _validate_etag_condition {
    my ($condition) = @_;
    my $bad = 'PAGI::Utils::Headers etag_matches condition must be a parsed entity-tag list';
    croak $bad unless ref($condition) eq 'HASH'
        && keys(%$condition) == 2 && exists($condition->{any}) && exists($condition->{tags})
        && defined($condition->{any}) && !ref($condition->{any})
        && $condition->{any} =~ /\A[01]\z/ && ref($condition->{tags}) eq 'ARRAY'
        && (!$condition->{any} || !@{$condition->{tags}});
    for my $tag (@{$condition->{tags}}) {
        croak $bad unless ref($tag) eq 'HASH' && keys(%$tag) == 2
            && exists($tag->{value}) && exists($tag->{weak})
            && defined($tag->{value}) && !ref($tag->{value})
            && $tag->{value} =~ /\A$ETAG_OPAQUE\z/
            && defined($tag->{weak}) && !ref($tag->{weak})
            && $tag->{weak} =~ /\A[01]\z/;
    }
}

sub _malformed_etag {
    my ($operation, $raise) = @_;
    croak "PAGI::Utils::Headers $operation received a malformed entity-tag value" if $raise;
    return undef;
}

sub parse_header_tokens {
    my ($value, @args) = @_;
    my $raise = _parser_options('parse_header_tokens', @args);
    return [] unless defined $value;
    croak 'PAGI::Utils::Headers parse_header_tokens value must be a scalar'
        if ref($value);

    my @tokens;
    for my $part (split /,/, $value, -1) {
        $part =~ s/\A[\x20\x09]+//;
        $part =~ s/[\x20\x09]+\z//;
        next unless length $part;
        unless ($part =~ /\A$HTTP_TOKEN\z/) {
            croak 'PAGI::Utils::Headers parse_header_tokens received a malformed token list'
                if $raise;
            return undef;
        }
        push @tokens, $part;
    }
    return \@tokens;
}

sub merge_vary {
    croak 'PAGI::Utils::Headers merge_vary requires an arrayref of existing values'
        unless @_ && ref($_[0]) eq 'ARRAY';
    my ($existing, @names) = @_;
    my @tokens;
    for my $value (@$existing) {
        croak 'PAGI::Utils::Headers merge_vary existing values must be scalars'
            unless defined($value) && !ref($value);
        my $parsed = parse_header_tokens($value);
        croak 'PAGI::Utils::Headers merge_vary received a malformed Vary field'
            unless defined $parsed;
        push @tokens, @$parsed;
    }
    for my $name (@names) {
        croak 'PAGI::Utils::Headers merge_vary field name must be an HTTP token or *'
            unless defined($name) && !ref($name) && $name =~ /\A$HTTP_TOKEN\z/;
        push @tokens, $name;
    }
    my (%seen, @unique);
    for my $token (@tokens) {
        my $key = _ascii_fold($token);
        next if $seen{$key}++;
        push @unique, $token;
    }
    return '*' if $seen{'*'};
    return join(', ', @unique);
}

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
                unless $value =~ /\A[A-Za-z0-9!#\$%&+\-\^_`{}~]+'(?:[A-Za-z]{1,8}(?:-[A-Za-z0-9]{1,8})*)?'(?:[A-Za-z0-9!#\$&+\-.\^_`|~]|%[0-9A-Fa-f]{2})*\z/;
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
      parse_header_tokens merge_vary
      parse_etag format_etag parse_etag_list etag_matches
  );

  my $token = parse_authorization_bearer($value, raise_on_error => 1);
  my ($user, $password) = parse_authorization_basic($value);
  my $challenge = www_authenticate('Bearer', realm => 'api');
  my $parsed = parse_header_parameters('attachment; filename="report; Q1.txt"');
  # { value => 'attachment', parameters => [filename => 'report; Q1.txt'] }
  my $field = format_header_parameters('attachment', filename => 'report; Q1.txt');
  my $quoted = quote_header_value('report.txt');
  my $download = content_disposition('attachment', filename => 'résumé.pdf');
  my $tokens = parse_header_tokens('gzip, br'); # ['gzip', 'br']
  my $vary = merge_vary(['Origin'], 'Accept-Encoding');
  # 'Origin, Accept-Encoding'
  my $tag = parse_etag('W/"v1"'); # { value => 'v1', weak => 1 }
  my $wire = format_etag('v2');    # '"v2"'
  my $condition = parse_etag_list(['"old"', 'W/"v2"']);
  my $not_modified = etag_matches($condition, '"v2"', weak => 1);

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

=head2 parse_header_tokens($value, %opts)

Parses one comma-separated list of HTTP tokens. It returns an arrayref in input
order, retaining spelling and repeated members. Empty members are skipped;
missing input and an empty list return C<[]>.

Only surrounding SP and HTAB are trimmed. A nonempty member containing quotes,
parameters, other delimiters, or invalid bytes makes the whole list unusable:
the default return is C<undef>, while C<raise_on_error =E<gt> 1> raises. Unknown
or duplicate options and reference input are programming errors. This function
does not parse cookies, dates, or general HTTP lists.

=head2 merge_vary(\@existing_values, @field_names)

Composes all existing C<Vary> field values and added field names into one value.
Names are deduplicated with ASCII case-insensitive comparison while first
spelling and order are retained. If any member is C<*>, the result is C<*>;
empty input returns an empty string. For example,
C<< merge_vary(['Origin', 'accept-encoding'], 'Accept-Encoding', 'Accept') >>
returns C<Origin, accept-encoding, Accept>.

The first argument must be an arrayref of scalar values. Existing nonempty
members and added names must be HTTP tokens. Malformed values and invalid
arguments raise; the function never silently drops a cache dependency.

=head2 parse_etag($value, %opts)

Parses one wire-format entity tag into C<< { value =E<gt> $opaque_bytes,
weak =E<gt> 0|1 } >>. The opaque bytes are kept literally: C<< W/"a,b\c" >>
has C<value> C<< a,b\c >>. Commas and backslashes are data, and quoted-string
unescaping is not applied. Outer SP and HTAB are ignored. Missing input returns
C<undef>; malformed syntax returns C<undef> or raises with C<raise_on_error =E<gt>
1>. A reference value or unknown/duplicate option is a programming error.

=head2 format_etag($opaque_bytes, weak =E<gt> $boolean)

Produces a wire-format ETag from unquoted opaque bytes. It defaults to strong
form: C<< format_etag('v2') >> returns C<< "v2" >>, and C<<
format_etag('v2', weak =E<gt> 1) >> returns C<< W/"v2" >>. Empty opaque
content is valid. Quotes, spaces, controls, and characters outside HTTP byte
syntax are rejected; the formatter never escapes or changes the content.
Invalid arguments and options always raise.

=head2 parse_etag_list(\@field_values, %opts)

Parses all C<If-Match> or C<If-None-Match> field occurrences in received order.
An empty input array means absence and returns C<undef>. A present empty list
returns C<< { any =E<gt> 0, tags =E<gt> [] } >>. Tag lists return C<< {
any =E<gt> 0, tags =E<gt> [ $tag, ... ] } >> with each tag in the
L</parse_etag($value, %opts)> shape; duplicates are retained. A standalone
wildcard returns C<< { any =E<gt> 1, tags =E<gt> [] } >>. Malformed syntax,
including a wildcard mixed with tags, returns C<undef> or raises with
C<raise_on_error =E<gt> 1>. The argument must be an arrayref of defined scalar
field values. No commas inside quoted tags are split.

=head2 etag_matches($condition, $current_wire_etag, weak =E<gt> $boolean)

Compares a parsed condition with a current wire-format ETag. Comparison is
strong by default, requiring both matching tags to be strong. C<weak =E<gt> 1>
compares opaque bytes regardless of strength. It returns false for an absent
condition or a present empty list. A wildcard matches a valid current ETag.
The current ETag is required and validated even when the condition is absent;
this function does not infer whether a representation exists without an ETag.
Invalid current tags and malformed parsed-condition arguments always raise.
The inputs are not changed.

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
