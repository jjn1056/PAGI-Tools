package PAGI::Headers;

use strict;
use warnings;
use Carp qw(croak);
use PAGI::Utils::Headers ();

my $HTTP_TOKEN = qr/[!#\$%&'*+\-.\^_`|~0-9A-Za-z]+/;

# Iterating @{$headers} yields the [name,value] pairs (the PAGI wire form), so
# `@{$res->headers}` callers keep working. READ-ONLY: it returns a COPY, so
# pushing onto it does not mutate the container -- use add(). Emission must use
# to_pairs, never this overload.
use overload '@{}' => sub { $_[0]->to_pairs }, fallback => 1;

=head1 NAME

PAGI::Headers - ordered, case-insensitive, multi-value HTTP header container

=head1 DESCRIPTION

Holds HTTP headers as an ordered list of C<[name, value]> byte pairs -- the PAGI
wire form. Lookup is case-insensitive (ASCII fold; field names are ASCII tokens);
original casing is preserved on output. Insertion order is preserved (never
sorted). Multiple values per name are first-class (e.g. C<Set-Cookie>).

Lookups scan the ordered list -- header sets are small, so this is deliberately
indexless.

This container is B<not> a hash and does not overload hash dereference; iterate
names with C<names> and read values with C<get>/C<get_all>, or take an explicit
plain-hash snapshot with C<to_hash>.

=head1 METHODS

=head2 new($pairs)

C<< PAGI::Headers->new([[Accept => 'text/plain'], [Accept => 'text/html']]) >>
copies an optional arrayref of C<[name, value]> pairs into an ordered container;
omitting it starts empty. The pair arrays are copied. Fields are not parsed or
normalized. Header values are HTTP wire bytes; application code must encode
characters before storing them.

=head2 get($name) and get_all($name)

C<< $headers->get('Accept') >> returns the last value, or C<undef> when absent.
C<< $headers->get_all('Accept') >> returns all values in order as a list, or
an empty list when absent. Both reads use ASCII case-insensitive names and
leave stored fields untouched. Use C<get_single> when duplicates must be
rejected rather than resolved by last-value lookup.

=head2 has($name), names, count, and is_empty

C<has> returns a boolean for any matching field. C<names> returns distinct
names in first-seen order and casing; C<count> counts pairs, including repeated
names, and C<is_empty> tests for zero pairs. For example, two C<Accept> fields
make C<< $headers->count >> return C<2> and C<< $headers->names >> return one
name. These methods do not mutate the container.

=head2 set($name, @values), add($name, @values), and set_default($name, $value)

C<set> removes all matching occurrences and appends the supplied values in
order; no values removes the field. C<add> appends without removing earlier
values. C<set_default> adds only when the field is absent. Each returns the
same Headers instance. For example, C<< $headers->add('Set-Cookie', 'a=1')
->add('Set-Cookie', 'b=2') >> keeps two fields. Values must be defined; callers
supply wire bytes. These raw writes do not escape or validate field contents.

=head2 remove($name), clear, and remove_content_headers

C<remove> deletes every matching occurrence and returns their values as a
list in original order. C<clear> removes all fields and returns the instance.
C<remove_content_headers> removes fields with names beginning C<Content-> and
returns a new Headers container holding the removed pairs. For example,
C<< my @old = $headers->remove('Vary') >> captures all previous Vary values.

=head2 clone, to_pairs, flatten, to_hash, and to_string

C<clone> returns an independent Headers container. C<to_pairs> returns a
detached arrayref of ordered C<[name, value]> pairs; C<flatten> returns the
ordered flat C<(name, value, ...)> list used by response headers. C<to_hash>
is the lossy last-value snapshot described below; C<to_hash(1)> keeps each
name's values in an arrayref. None of these output methods mutate fields.
Array dereference also returns a copy of the pair list, so use C<add> or C<set>
to make a change.

C<to_string> joins the stored pairs as raw C<"Name: value\r\n"> lines for
debugging and inspection only. It does not validate or remove C<CR> or C<LF>
from values, so its output is unsafe for untrusted fields. Use C<to_pairs> for
PAGI wire emission.

=head2 dehop

Removes standard hop-by-hop fields and fields nominated by C<Connection>;
returns the same instance. Use C<< $headers->clone->dehop >> if the original
fields must remain available. This raw forwarding aid does not parse other
field grammars.

=head2 to_hash

    my $flat  = $headers->to_hash;     # { Name => last-value }
    my $multi = $headers->to_hash(1);  # { Name => [ all values ] }

Returns a plain hashref snapshot keyed by distinct header name (grouped
case-insensitively, using the casing and order C<names> reports). The flat form
mirrors C<get> -- one value per name, last wins. Passing a true argument returns
the multi-value form, mirroring C<get_all> -- an arrayref of every value for each
name. Values are B<not> comma-joined (unlike L<HTTP::Headers>/L<Mojo::Headers>).

Header values are opaque bytes and pass through untouched -- including C<CR>,
C<LF>, and C<NUL>. This container does B<not> validate or sanitize them; rejecting
injection bytes on the wire is the server's job, which it B<MUST> do when emitting
a response (see L<PAGI::Spec::Www/"Response Start - send event">). A value must,
however, be B<defined>: C<add>, C<set>, and C<set_default> C<croak> on an C<undef>
value rather than storing it, since an undefined header value is a caller bug, not
data.

=head2 get_single($name, %opts)

Returns a raw field value only when exactly one case-insensitive occurrence of
C<$name> exists. Missing fields return C<undef>. Duplicate fields, even with
identical values, also return C<undef> by default, or raise with
C<raise_on_error =E<gt> 1>. An empty present value remains an empty string;
the value is not trimmed, parsed, or rewritten. The only option is
C<raise_on_error>; unknown or duplicate options are errors. For example,
C<< $headers->get_single('Authorization', raise_on_error => 1) >> rejects two
Authorization occurrences.

=head2 tokens($name, %opts)

Parses every occurrence of the named field as a comma-separated token list and
returns one arrayref in field order, retaining original spelling and duplicates.
Missing fields and empty lists return C<[]>; a malformed member in any occurrence
returns C<undef> by default or raises with C<raise_on_error =E<gt> 1>. It uses
L<PAGI::Utils::Headers/parse_header_tokens($value, %opts)> and does not rewrite
stored fields. For example, two C<X-Flags> fields containing C<a, b> and C<a>
produce C<['a', 'b', 'a']>. Unknown or duplicate options are errors.

=head2 has_token($name, $token, %opts)

Returns a boolean membership result for the combined token list. Comparison is
exact by default; C<case_insensitive =E<gt> 1> uses ASCII case folding, so
C<< $headers-E<gt>has_token('Connection', 'close', case_insensitive =E<gt> 1) >>
also matches C<Close>. Missing, empty, and malformed lists return false by
default. C<raise_on_error =E<gt> 1> raises for malformed lists. The candidate
must be an HTTP token; unknown or duplicate options are errors. Reading does
not deduplicate or change the stored fields.

=head2 add_vary(@field_names)

Merges every existing C<Vary> occurrence with the supplied field names and
replaces those occurrences with one C<Vary> field. It returns the same Headers
instance for chaining; with no existing values and no new names it makes no
change. For example, C<< $headers-E<gt>add_vary('Accept-Encoding') >> adds the
cache dependency once. First spelling and order are retained, and any wildcard
normalizes to C<*>. A malformed existing member or invalid new name raises
before the container is changed. Unrelated repeated fields remain separate.

=head2 authorization_bearer(%opts)

Reads a single Authorization field and returns its opaque Bearer token. Missing
fields, duplicate fields, another identifiable scheme, and malformed input
return C<undef> by default. C<raise_on_error =E<gt> 1> raises for duplicates or
malformed Bearer credentials. Parsing uses the shared
L<PAGI::Utils::Headers/parse_authorization_bearer($value, %opts)> rules and does
not verify or decode the token. For example, one C<Authorization: Bearer
accepted> field yields C<accepted>.

=head2 authorization_basic(%opts)

Reads a single Authorization field and returns C<(username, password)> in list
context after shared Basic parsing. It returns C<(undef, undef)> for missing,
duplicate, another-scheme, or malformed input by default. C<raise_on_error =E<gt>
1> raises for duplicates or malformed Basic credentials. Credential bytes are
not decoded as characters or verified. One C<Authorization: Basic
YWRhOnRlc3Q=> field yields C<('ada', 'test')> in list context.

=head2 content_type(%opts)

Returns the lowercased media type from one valid C<Content-Type> field, such as
C<text/html> from C<Text/HTML; charset=UTF-8>. The leading value must be
C<token/token>. Missing, duplicate, or malformed fields return C<undef>.
C<raise_on_error =E<gt> 1> raises for duplicate or malformed input, but not
absence. Use C<get('Content-Type')> for the raw last-value lookup.

=head2 content_type_parameters(%opts)

Returns a hashref of parameters from one valid C<Content-Type> field; a valid
field without parameters returns C<{}>. Names are ASCII-lowercased, while value
bytes are preserved. For example, C<Text/HTML; charset=UTF-8> produces
C<< { charset =E<gt> 'UTF-8' } >>. Case-insensitive duplicate parameter names
make the whole field unusable. Missing and unusable fields return C<undef>.
Unknown parameters remain available.

=head2 content_disposition(%opts)

Returns the lowercased disposition token from one valid C<Content-Disposition>
field, such as C<attachment>. Missing, duplicate, or malformed fields return
C<undef>, with the same C<raise_on_error> behavior as C<content_type>.
Use C<get('Content-Disposition')> for the raw last-value lookup.

=head2 content_disposition_parameters(%opts)

Returns a hashref of parameters from one valid C<Content-Disposition> field;
a valid field without parameters returns C<{}>. For example, C<< attachment;
filename="report; Q1.txt" >> gives C<< { filename =E<gt> 'report; Q1.txt' } >>.
Unknown names remain available, and C<filename*> stays distinct from
C<filename> with its encoded bytes unchanged. Duplicate names, ignoring ASCII
case, make the field unusable. Missing and unusable fields return C<undef>.

All four named reads accept only C<raise_on_error>. They use the shared
parameter grammar and do not rewrite fields or cache parsed values. Returned
hashes are detached from the stored field; write a new value with C<set> and
L<PAGI::Utils::Headers/format_header_parameters($leading, name =E<gt> $value, ...)>.

=head2 etag(%opts)

Parses exactly one C<ETag> occurrence as C<< { value =E<gt> $opaque_bytes,
weak =E<gt> 0|1 } >>. Missing, duplicate, or malformed fields return C<undef>.
C<raise_on_error =E<gt> 1> reports duplicates and malformed fields, not absence.
For example, C<< ETag: W/"v1" >> yields
C<< { value =E<gt> 'v1', weak =E<gt> 1 } >>.

=head2 if_none_match(%opts) and if_match(%opts)

Each reads all occurrences of its conditional field in order and returns
C<< { any =E<gt> 0, tags =E<gt> \@tags } >> or
C<< { any =E<gt> 1, tags =E<gt> [] } >> for a wildcard. Absence returns
C<undef>; a present empty list has an empty C<tags> array. Malformed syntax
returns C<undef> by default or raises with C<raise_on_error =E<gt> 1>.
All three readers leave raw fields untouched and reject unknown options. Two
C<If-None-Match> fields holding C<< "old" >> and C<< W/"a,b" >> produce two
tags, keeping the comma inside the second tag.

=cut

# ASCII-only lowercase for name keying. Field names are ASCII tokens (RFC 7230);
# Perl's lc() is Unicode-aware and could mis-fold stray bytes.
sub _fold { my $k = $_[0]; $k =~ tr/A-Z/a-z/; return $k }

# Hop-by-hop headers (RFC 7230 §6.1) -- not safe to forward through a proxy.
my %HOP = map { $_ => 1 } qw(
    connection keep-alive proxy-authenticate proxy-authorization
    te trailer transfer-encoding upgrade
);

sub new {
    my ($class, $pairs) = @_;
    my @p;
    if (defined $pairs) {
        croak("PAGI::Headers->new expects an arrayref of [name, value] pairs")
            unless ref($pairs) eq 'ARRAY';
        @p = map { [ $_->[0], $_->[1] ] } @$pairs;
    }
    return bless { pairs => \@p }, $class;
}

sub clone { return PAGI::Headers->new($_[0]->{pairs}) }

# --- reads (case-insensitive) ---

sub get {
    my ($self, $name) = @_;
    croak("header name required") unless defined $name;
    my $key = _fold($name);
    my $val;
    for my $p (@{$self->{pairs}}) { $val = $p->[1] if _fold($p->[0]) eq $key }
    return $val;
}

sub get_all {
    my ($self, $name) = @_;
    croak("header name required") unless defined $name;
    my $key = _fold($name);
    return map { $_->[1] } grep { _fold($_->[0]) eq $key } @{$self->{pairs}};
}

sub get_single {
    my ($self, $name, @args) = @_;
    my $raise = _read_options('get_single', @args);
    croak("header name required") unless defined $name;
    my @values = $self->get_all($name);
    return undef unless @values;
    if (@values > 1) {
        croak('PAGI::Headers get_single found multiple occurrences of one field') if $raise;
        return undef;
    }
    return $values[0];
}

sub tokens {
    my ($self, $name, @args) = @_;
    my $raise = _read_options('tokens', @args);
    croak 'PAGI::Headers tokens header name required'
        unless defined($name) && !ref($name) && length($name);
    my @tokens;
    for my $value ($self->get_all($name)) {
        my $parsed = PAGI::Utils::Headers::parse_header_tokens($value);
        unless (defined $parsed) {
            croak 'PAGI::Headers tokens received a malformed token list' if $raise;
            return undef;
        }
        push @tokens, @$parsed;
    }
    return \@tokens;
}

sub has_token {
    my ($self, $name, $token, @args) = @_;
    croak 'PAGI::Headers has_token candidate must be an HTTP token'
        unless defined($token) && !ref($token) && $token =~ /\A$HTTP_TOKEN\z/;
    my %opts = _token_options('has_token', @args);
    my $tokens = $self->tokens($name);
    unless (defined $tokens) {
        croak 'PAGI::Headers has_token received a malformed token list'
            if $opts{raise_on_error};
        return 0;
    }
    my $wanted = $opts{case_insensitive} ? _fold($token) : $token;
    for my $item (@$tokens) {
        return 1 if ($opts{case_insensitive} ? _fold($item) : $item) eq $wanted;
    }
    return 0;
}

sub authorization_bearer {
    my ($self, @args) = @_;
    my $value = $self->get_single('Authorization', @args);
    return PAGI::Utils::Headers::parse_authorization_bearer($value, @args);
}

sub authorization_basic {
    my ($self, @args) = @_;
    my $value = $self->get_single('Authorization', @args);
    return PAGI::Utils::Headers::parse_authorization_basic($value, @args);
}

sub etag {
    my ($self, @args) = @_;
    my $raise = _read_options('etag', @args);
    my @values = $self->get_all('ETag');
    return undef unless @values;
    if (@values > 1) {
        croak 'PAGI::Headers etag found multiple ETag occurrences' if $raise;
        return undef;
    }
    my $parsed = PAGI::Utils::Headers::parse_etag($values[0]);
    unless (defined $parsed) {
        croak 'PAGI::Headers etag received a malformed ETag field' if $raise;
        return undef;
    }
    return $parsed;
}

sub if_none_match {
    my ($self, @args) = @_;
    return $self->_etag_condition_field('if_none_match', 'If-None-Match', @args);
}

sub if_match {
    my ($self, @args) = @_;
    return $self->_etag_condition_field('if_match', 'If-Match', @args);
}

sub _etag_condition_field {
    my ($self, $method, $field, @args) = @_;
    my $raise = _read_options($method, @args);
    my @values = $self->get_all($field);
    my $parsed = PAGI::Utils::Headers::parse_etag_list(\@values);
    if (!defined($parsed) && @values && $raise) {
        croak "PAGI::Headers $method received a malformed $field field";
    }
    return $parsed;
}

sub content_type {
    my ($self, @args) = @_;
    my $parsed = $self->_parameterized_field('content_type', 'Content-Type', 'media', @args);
    return $parsed ? $parsed->{value} : undef;
}

sub content_type_parameters {
    my ($self, @args) = @_;
    my $parsed = $self->_parameterized_field('content_type_parameters', 'Content-Type', 'media', @args);
    return $parsed ? $parsed->{parameters} : undef;
}

sub content_disposition {
    my ($self, @args) = @_;
    my $parsed = $self->_parameterized_field('content_disposition', 'Content-Disposition', 'token', @args);
    return $parsed ? $parsed->{value} : undef;
}

sub content_disposition_parameters {
    my ($self, @args) = @_;
    my $parsed = $self->_parameterized_field('content_disposition_parameters', 'Content-Disposition', 'token', @args);
    return $parsed ? $parsed->{parameters} : undef;
}

sub _parameterized_field {
    my ($self, $method, $field, $grammar, @args) = @_;
    my $raise = _read_options($method, @args);
    my @values = $self->get_all($field);
    return undef unless @values;
    if (@values > 1) {
        croak "PAGI::Headers $method found multiple occurrences of $field" if $raise;
        return undef;
    }
    my $value = $values[0];
    my $parsed = PAGI::Utils::Headers::parse_header_parameters($value);
    unless ($parsed) {
        croak "PAGI::Headers $method received a malformed $field field" if $raise;
        return undef;
    }
    my $leading = $parsed->{value};
    my $valid = $grammar eq 'media'
        ? $leading =~ /\A$HTTP_TOKEN\/$HTTP_TOKEN\z/
        : $leading =~ /\A$HTTP_TOKEN\z/;
    unless ($valid) {
        croak "PAGI::Headers $method has an invalid $field leading value" if $raise;
        return undef;
    }
    my (%parameters, %seen);
    my @pairs = @{$parsed->{parameters}};
    while (@pairs) {
        my ($name, $parameter) = splice @pairs, 0, 2;
        if ($seen{$name}++) {
            croak "PAGI::Headers $method has duplicate $field parameters" if $raise;
            return undef;
        }
        $parameters{$name} = $parameter;
    }
    return { value => _fold($leading), parameters => \%parameters };
}

sub has {
    my ($self, $name) = @_;
    return 0 unless defined $name && length $name;
    my $key = _fold($name);
    for my $p (@{$self->{pairs}}) { return 1 if _fold($p->[0]) eq $key }
    return 0;
}

sub names {
    my ($self) = @_;
    my (%seen, @names);
    for my $p (@{$self->{pairs}}) {
        push @names, $p->[0] unless $seen{ _fold($p->[0]) }++;
    }
    return @names;
}

sub count    { scalar @{ $_[0]->{pairs} } }
sub is_empty { @{ $_[0]->{pairs} } ? 0 : 1 }

# --- writes (return $self) ---

sub set {
    my ($self, $name, @values) = @_;
    croak("header name required") unless defined $name;
    croak("header value must be defined") if grep { !defined } @values;
    my $key = _fold($name);
    @{$self->{pairs}} = grep { _fold($_->[0]) ne $key } @{$self->{pairs}};
    push @{$self->{pairs}}, [ $name, $_ ] for @values;
    return $self;
}

sub add {
    my ($self, $name, @values) = @_;
    croak("header name required") unless defined $name;
    croak("header value must be defined") if grep { !defined } @values;
    push @{$self->{pairs}}, [ $name, $_ ] for @values;
    return $self;
}

sub set_default {
    my ($self, $name, $value) = @_;
    return $self if $self->has($name);
    return $self->add($name, $value);
}

sub add_vary {
    my ($self, @names) = @_;
    my @existing = $self->get_all('Vary');
    return $self unless @existing || @names;
    my $value = PAGI::Utils::Headers::merge_vary(\@existing, @names);
    return $self->set('Vary', $value);
}

sub remove {
    my ($self, $name) = @_;
    croak("header name required") unless defined $name;
    my $key = _fold($name);
    my @removed = map { $_->[1] } grep { _fold($_->[0]) eq $key } @{$self->{pairs}};
    @{$self->{pairs}} = grep { _fold($_->[0]) ne $key } @{$self->{pairs}};
    return @removed;
}

sub clear { @{ $_[0]->{pairs} } = (); return $_[0] }

sub remove_content_headers {
    my ($self) = @_;
    my @removed = grep {  _fold($_->[0]) =~ /^content-/ } @{$self->{pairs}};
    @{$self->{pairs}} = grep { _fold($_->[0]) !~ /^content-/ } @{$self->{pairs}};
    return PAGI::Headers->new(\@removed);
}

# Strip hop-by-hop headers: the fixed RFC 7230 set PLUS any field NAMED by the
# Connection header (e.g. "Connection: X-Secret" makes X-Secret hop-by-hop).
sub dehop {
    my ($self) = @_;
    my %drop = %HOP;
    for my $conn ($self->get_all('connection')) {
        for my $tok (split /,/, $conn) {
            $tok =~ s/\A\s+//; $tok =~ s/\s+\z//;
            $drop{ _fold($tok) } = 1 if length $tok;
        }
    }
    @{$self->{pairs}} = grep { !$drop{ _fold($_->[0]) } } @{$self->{pairs}};
    return $self;
}

# --- output ---

sub to_pairs { return [ map { [ $_->[0], $_->[1] ] } @{ $_[0]->{pairs} } ] }
sub flatten  { return map { @$_ } @{ $_[0]->{pairs} } }

# Plain-hash snapshot, keyed by distinct name (case-insensitively grouped, in
# names() order/casing). Flat form mirrors get() -- one value per name, last
# wins; multi form (truthy arg) mirrors get_all() -- an arrayref of every value.
# This is the explicit "I want a hash" path; the container itself is NOT a hash.
sub to_hash {
    my ($self, $multi) = @_;
    return { map { $_ => [ $self->get_all($_) ] } $self->names } if $multi;
    return { map { $_ => $self->get($_) } $self->names };
}

sub _read_options {
    my ($method, @args) = @_;
    croak "PAGI::Headers $method options must be key/value pairs" if @args % 2;
    my %opts;
    while (@args) {
        my ($name, $value) = splice @args, 0, 2;
        croak "PAGI::Headers $method option names must be defined scalars"
            unless defined($name) && !ref($name);
        croak "PAGI::Headers $method has unknown option '$name'"
            unless $name eq 'raise_on_error';
        croak "PAGI::Headers $method has duplicate option '$name'"
            if exists $opts{$name};
        $opts{$name} = $value;
    }
    return $opts{raise_on_error} ? 1 : 0;
}

sub _token_options {
    my ($method, @args) = @_;
    croak "PAGI::Headers $method options must be key/value pairs" if @args % 2;
    my %opts;
    while (@args) {
        my ($name, $value) = splice @args, 0, 2;
        croak "PAGI::Headers $method option names must be defined scalars"
            unless defined($name) && !ref($name);
        croak "PAGI::Headers $method has unknown option '$name'"
            unless $name eq 'raise_on_error' || $name eq 'case_insensitive';
        croak "PAGI::Headers $method has duplicate option '$name'"
            if exists $opts{$name};
        $opts{$name} = $value;
    }
    return %opts;
}

# Debug/inspection only -- NOT a wire-emission helper. It does not validate or
# strip CR/LF, so it is unsafe for untrusted header values; wire safety is the
# server's job (it validates http.response.start). The real output is to_pairs.
sub to_string { return join('', map { "$_->[0]: $_->[1]\r\n" } @{ $_[0]->{pairs} }) }

1;
