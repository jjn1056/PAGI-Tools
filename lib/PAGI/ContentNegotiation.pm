package PAGI::ContentNegotiation;
use strict;
use warnings;
use Carp qw(croak);
use Exporter 'import';
use Scalar::Util qw(blessed);
use PAGI::Utils::Scope ();

our @EXPORT = ();
our @EXPORT_OK = qw(content_negotiation negotiated_type respond_to);
our %EXPORT_TAGS = (all => [@EXPORT_OK]);

=head1 NAME

PAGI::ContentNegotiation - HTTP content negotiation: Accept matching, and the negotiated choice for handlers

=head1 SYNOPSIS

    use PAGI::Tools qw(compose middleware respond_to response route);

    my $note = { id => 1, text => 'buy milk' };

    # The middleware chooses from Accept, answers 406, and sends Vary: Accept;
    # the handler says what each representation is.
    my $app = compose(routes => [route('/note' => sub {
        my ($request) = @_;
        return respond_to($request,
            html => sub { response('HTML', "<h1>$note->{text}</h1>") },
            json => sub { response('JSON', $note) },
        );
    }, middleware => [middleware('ContentNegotiation', supported_types => ['html', 'json'])])]);

The Accept-matching engine underneath is a set of class methods:

    my $best = PAGI::ContentNegotiation->best_match(['json', 'html'], 'text/html, application/json;q=0.9');

=head1 DESCRIPTION

Two things live here. The handler side reads the choice that
L<PAGI::Middleware::ContentNegotiation> made for this request: the
functions C<respond_to>, C<negotiated_type> and C<content_negotiation>, and
the object they return. The engine is a set of class methods that parse
Accept headers and pick the best match; the middleware,
L<PAGI::Request/preferred_type> and L<PAGI::Pages> all use it.

Use the middleware and the functions when a route answers in more than one
representation: it owns C<Vary: Accept> and the 406, so a handler cannot
forget them. Use C<< $request->preferred_type(@types) >> where there is no
middleware (an C<http_default> or ErrorHandler handler); then the handler
writes C<Vary: Accept> itself.

The engine supports quality values, wildcards (C<*/*>, C<type/*>), and
common shortcuts (C<json>, C<html>, C<xml>, ...).

=head1 CLASS METHODS

=cut

# Common MIME type shortcuts
my %TYPE_SHORTCUTS = (
    html => 'text/html',
    text => 'text/plain',
    txt  => 'text/plain',
    json => 'application/json',
    xml  => 'application/xml',
    atom => 'application/atom+xml',
    rss  => 'application/rss+xml',
    css  => 'text/css',
    js   => 'application/javascript',
    png  => 'image/png',
    jpg  => 'image/jpeg',
    jpeg => 'image/jpeg',
    gif  => 'image/gif',
    svg  => 'image/svg+xml',
    pdf  => 'application/pdf',
    zip  => 'application/zip',
    form => 'application/x-www-form-urlencoded',
);

=head2 parse_accept

    my @types = PAGI::ContentNegotiation->parse_accept($header);

Parse an Accept header and return a list of arrayrefs containing
C<[media_type, quality]> sorted by preference (quality descending,
then specificity descending).

If no Accept header is provided, returns a single entry for C<*/*> with
quality 1.

Quality values are clamped to the range [0, 1].

Specificity ordering: exact types > type/* > */*

=cut

sub parse_accept {
    my ($class, $header) = @_;
    # No Accept header means accept everything
    return (['*/*', 1]) unless defined $header && length $header;

    my @types;

    for my $part (split /\s*,\s*/, $header) {
        # Parse: type/subtype;param=value;q=0.9;ext=value
        my ($type, @params) = split /\s*;\s*/, $part;
        next unless defined $type && length $type;

        # Normalize type
        $type = lc($type);
        $type =~ s/^\s+//;
        $type =~ s/\s+$//;

        # Extract quality value (default 1)
        my $quality = 1;
        for my $param (@params) {
            if ($param =~ /^q\s*=\s*(-?[0-9.]+)$/i) {
                $quality = $1 + 0;  # Convert to number
                $quality = 1 if $quality > 1;
                $quality = 0 if $quality < 0;
                last;
            }
        }

        push @types, [$type, $quality];
    }

    # Sort by quality (highest first), then by specificity
    @types = sort {
        # Primary: quality (descending)
        my $cmp = $b->[1] <=> $a->[1];
        return $cmp if $cmp;

        # Secondary: specificity (more specific first)
        # */* < type/* < type/subtype
        my $spec_a = _specificity($a->[0]);
        my $spec_b = _specificity($b->[0]);
        return $spec_b <=> $spec_a;
    } @types;

    return @types;
}

# Calculate specificity score for sorting
# Returns: 0 for */*, 1 for type/*, 2 for type/subtype
sub _specificity {
    my ($type) = @_;
    return 0 if $type eq '*/*';
    return 1 if $type =~ m{^[^/]+/\*$};
    return 2;
}

=head2 best_match

    my $type = PAGI::ContentNegotiation->best_match(\@supported, $accept_header);

Find the best matching content type from C<@supported> based on the
Accept header. Returns the best match or undef if none acceptable.

C<@supported> can contain full MIME types or shortcuts (html, json, xml, etc.)

The returned value is from the C<@supported> array (preserves shortcuts).

=cut

sub best_match {
    my ($class, $supported, $accept_header) = @_;
    return unless $supported && @$supported;

    my ($winner, $winner_q);
    for my $candidate (@$supported) {
        my $q = $class->quality_for_type($accept_header, $candidate);
        next unless $q > 0;
        if (!defined($winner) || $q > $winner_q) {
            ($winner, $winner_q) = ($candidate, $q);
        }
    }

    return $winner;
}

=head2 type_matches

    my $bool = PAGI::ContentNegotiation->type_matches($type, $pattern);

Check if a media type matches a pattern. Patterns can include wildcards
like C<*/*> or C<text/*>.

Both type and pattern are compared case-insensitively.

=cut

sub type_matches {
    my ($class, $type, $pattern) = @_;
    $type = lc($type);
    $pattern = lc($pattern);

    # Exact match
    return 1 if $type eq $pattern;

    # Wildcard match
    return 1 if $pattern eq '*/*';

    # Type wildcard (e.g., text/*)
    if ($pattern =~ m{^([^/]+)/\*$}) {
        my $major = $1;
        return 1 if $type =~ m{^\Q$major\E/};
    }

    return 0;
}

=head2 normalize_type

    my $mime = PAGI::ContentNegotiation->normalize_type($type);

Convert a type shortcut to its full MIME type. Known shortcuts include:

    html   => text/html
    json   => application/json
    xml    => application/xml
    atom   => application/atom+xml
    rss    => application/rss+xml
    text   => text/plain
    txt    => text/plain
    css    => text/css
    js     => application/javascript
    png    => image/png
    jpg    => image/jpeg
    jpeg   => image/jpeg
    gif    => image/gif
    svg    => image/svg+xml
    pdf    => application/pdf
    zip    => application/zip
    form   => application/x-www-form-urlencoded

If the type is already a MIME type (contains '/'), it's returned as-is.

Unknown shortcuts are prefixed with 'application/'.

=cut

sub normalize_type {
    my ($class, $type) = @_;
    return $type if $type =~ m{/};
    return $TYPE_SHORTCUTS{lc($type)} // "application/$type";
}

=head2 is_known_type

    PAGI::ContentNegotiation->is_known_type('json');            # 1
    PAGI::ContentNegotiation->is_known_type('application/x-y'); # 1
    PAGI::ContentNegotiation->is_known_type('htlm');            # 0

True for a media type (anything containing C</>) or a shortcut in the table
above, in any case. L<PAGI::Middleware::ContentNegotiation> refuses
C<supported_types> entries for which it is false, because
C<normalize_type> turns an unknown name into C<application/E<lt>nameE<gt>>
and a typo would never match.

=cut

sub is_known_type {
    my ($class, $type) = @_;
    return 0 unless defined $type && length $type;
    return 1 if $type =~ m{/};
    return exists $TYPE_SHORTCUTS{lc $type} ? 1 : 0;
}

=head2 shortcuts

    my @names = PAGI::ContentNegotiation->shortcuts;   # atom, css, form, ...

The shortcut names C<normalize_type> knows, sorted.

=cut

sub shortcuts {
    return sort keys %TYPE_SHORTCUTS;
}

=head2 accepts_type

    my $bool = PAGI::ContentNegotiation->accepts_type($accept_header, $type);

Check if a specific content type is acceptable based on the Accept header.

The type can be a full MIME type or a shortcut.

Returns false if the type has quality=0 (explicitly rejected).

=cut

sub accepts_type {
    my ($class, $accept_header, $type) = @_;
    $type = $class->normalize_type($type);

    return $class->quality_for_type($accept_header, $type) > 0
        unless $type =~ m{\*};

    return 1 if $class->quality_for_type($accept_header, $type) > 0;

    my @accepted = $class->parse_accept($accept_header);

    for my $accepted (@accepted) {
        my ($concrete) = @$accepted;
        next if $concrete =~ m{\*};
        next unless $class->type_matches($concrete, $type);

        return 1 if $class->quality_for_type($accept_header, $concrete) > 0;
    }

    return 0;
}

=head2 quality_for_type

    my $q = PAGI::ContentNegotiation->quality_for_type($accept_header, $type);

Get the quality value for a specific type. Returns 0 if not acceptable.

When multiple patterns match (e.g., both text/* and text/html), returns
the quality of the most specific match.

The type can be a full MIME type or a shortcut.

=cut

sub quality_for_type {
    my ($class, $accept_header, $type) = @_;
    $type = $class->normalize_type($type);

    my @accepted = $class->parse_accept($accept_header);

    my $best_quality = 0;
    my $best_specificity = -1;

    for my $accepted (@accepted) {
        my ($pattern, $quality) = @$accepted;

        if ($class->type_matches($type, $pattern)) {
            my $spec = _specificity($pattern);
            if ($spec > $best_specificity ||
                ($spec == $best_specificity && $quality > $best_quality)) {
                $best_quality = $quality;
                $best_specificity = $spec;
            }
        }
    }

    return $best_quality;
}

=head1 FUNCTIONS

Opt-in named exports, also available through C<:all> and from
L<PAGI::Tools>. Nothing is exported by default. Each takes a scope hashref or
an object with a C<scope> method (a L<PAGI::Request>).

=head2 content_negotiation

    my $cn = content_negotiation($request);

The negotiated choice for this request, as an object; the same as
C<< PAGI::ContentNegotiation->new($request) >>.

=head2 negotiated_type

    my $type = negotiated_type($request);   # 'json'

The chosen type as written in C<supported_types>, or undef when nothing was
acceptable (only with C<refuse =E<gt> 0>). The same as
C<< content_negotiation($request)->type >>.

=head2 respond_to

    return respond_to($request,
        html => sub { response('HTML', $page) },
        json => sub { response('JSON', $data) },
    );

Calls the branch for the chosen type and returns its result. The same as
the C<respond_to> method under L</METHODS>,
C<< content_negotiation($request)->respond_to(...) >>.

=cut

sub content_negotiation { return __PACKAGE__->new(@_) }

sub negotiated_type { return __PACKAGE__->new(@_)->type }


=head1 CONSTRUCTOR

=head2 new

    my $cn = PAGI::ContentNegotiation->new($request);   # or $scope

Reads the C<pagi.content_negotiation> record that
L<PAGI::Middleware::ContentNegotiation> puts in the scope. Dies when the
scope is not HTTP, and when the middleware has not run.

=head2 from_data

    my $cn = PAGI::ContentNegotiation->from_data({ type => 'json', supported => ['html', 'json'] });

Test convenience constructor over a record of your own. C<supported> is
required; C<type> defaults to undef and C<refusing> to 1.

=cut

sub new {
    my ($class, @args) = @_;
    my $scope = PAGI::Utils::Scope::scope_from_source($class, @args);
    my $type = $scope->{type} // '';
    croak "PAGI::ContentNegotiation applies to HTTP requests only (scope type '$type')"
        unless $type eq 'http';
    croak 'PAGI::ContentNegotiation requires ContentNegotiation middleware (missing pagi.content_negotiation)'
        unless exists $scope->{'pagi.content_negotiation'};
    return bless { _record => $scope->{'pagi.content_negotiation'} }, $class;
}

sub from_data {
    my ($class, $data) = @_;
    die "from_data() requires a hashref\n" unless ref $data eq 'HASH';
    die "from_data() requires supported, a non-empty arrayref\n"
        unless ref($data->{supported}) eq 'ARRAY' && @{$data->{supported}};
    return bless { _record => { type => undef, refusing => 1, %$data } }, $class;
}

=head1 METHODS

=head2 type

The chosen type as written in C<supported_types> (C<json>, or
C<application/json> if that is how it was declared); undef when nothing was
acceptable.

=head2 media_type

The chosen type as a media type (C<application/json>); undef likewise.

=head2 supported

The declared types, in preference order, as a list.

=head2 is

    if ($cn->is('json')) { ... }

True when C<$name> was chosen. Names are compared exactly as declared. A
name that was not declared dies, so a typo fails at once instead of quietly
never matching.

=head2 respond_to

    return $cn->respond_to(
        html => sub { response('HTML', $page) },
        json => sub { response('JSON', $data) },
    );

Calls the branch for the chosen type, with no arguments, and returns what it
returns. Before calling anything it checks the branches, so a mistake fails
on the first request whatever the client sent:

=over 4

=item * every declared type has a branch, and every key is a declared type;

=item * each branch is a code reference;

=item * C<none>, called when nothing was acceptable, is given when the
middleware has C<refuse =E<gt> 0> and only then.

=back

Branches are synchronous: a branch that returns a Future dies. Do the
asynchronous work first and build the response in the branch, or read
L</type> and branch yourself. (An C<async> handler that returned a Future
from C<respond_to> would resolve to that Future rather than a response.)

The middleware owns C<Vary: Accept> and the 406; C<respond_to> writes no
headers. A response thrown with C<die> skips the middleware's C<Vary>, so a
handler returns, rather than throws, an error it picked by the negotiated
type.

=cut

sub type { return $_[0]{_record}{type} }

sub media_type {
    my ($self) = @_;
    my $type = $self->type;
    return defined $type ? __PACKAGE__->normalize_type($type) : undef;
}

sub supported { return @{ $_[0]{_record}{supported} } }

sub is {
    my ($self, $name) = @_;
    $self->_require_declared($name);
    my $type = $self->type;
    return defined($type) && $type eq $name ? 1 : 0;
}

sub respond_to {
    my ($source, @pairs) = @_;
    my $self = blessed($source) && $source->isa(__PACKAGE__)
        ? $source
        : __PACKAGE__->new($source);
    croak 'PAGI::ContentNegotiation: respond_to takes name => code pairs' if @pairs % 2;
    my %branch;
    while (my ($name, $code) = splice @pairs, 0, 2) {
        $self->_require_declared($name) unless defined($name) && $name eq 'none';
        croak "PAGI::ContentNegotiation: the '$name' branch must be a code reference"
            unless ref $code eq 'CODE';
        $branch{$name} = $code;
    }
    my @missing = grep { !$branch{$_} } $self->supported;
    croak 'PAGI::ContentNegotiation: respond_to needs a branch for every declared type; missing: '
        . join(', ', @missing) if @missing;
    my $refusing = $self->{_record}{refusing};
    croak 'PAGI::ContentNegotiation: respond_to needs a none branch when the middleware has refuse => 0'
        if !$refusing && !$branch{none};
    croak 'PAGI::ContentNegotiation: a none branch is never called while the middleware refuses unacceptable requests'
        if $refusing && $branch{none};
    my $type = $self->type;
    croak 'PAGI::ContentNegotiation: nothing was acceptable, so respond_to has no branch to call; a refuse answer returns its response directly'
        if !defined($type) && $refusing;
    my $name = defined $type ? $type : 'none';
    my $result = $branch{$name}->();
    croak "PAGI::ContentNegotiation: the '$name' branch returned a Future; do async work before respond_to and return a response from the branch"
        if blessed($result) && $result->isa('Future');
    return $result;
}

sub _require_declared {
    my ($self, $name) = @_;
    croak 'PAGI::ContentNegotiation: a type name is required' unless defined $name;
    return if grep { $_ eq $name } $self->supported;
    croak "PAGI::ContentNegotiation: '$name' is not one of the declared types ("
        . join(', ', $self->supported) . ')';
}

=head1 EXAMPLES

=head2 Content Negotiation in a PAGI App

    use PAGI::Request;
    use PAGI::ContentNegotiation;

    async sub app ($scope, $receive, $send) {
        # Scope headers are an arrayref of [name, value] pairs, not a hash.
        # Read them through PAGI::HTTPConnection, not $scope->{headers}{...}.
        my $req    = PAGI::Request->new($scope, $receive);
        my $accept = $req->header('accept') // '*/*';

        my $format = PAGI::ContentNegotiation->best_match(
            ['json', 'html', 'xml'],
            $accept
        );

        my ($body, $content_type);
        if ($format eq 'json') {
            $body = '{"message":"Hello"}';
            $content_type = 'application/json';
        } elsif ($format eq 'html') {
            $body = '<h1>Hello</h1>';
            $content_type = 'text/html';
        } else {
            $body = '<message>Hello</message>';
            $content_type = 'application/xml';
        }

        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', $content_type]],
        });

        await $send->({
            type => 'http.response.body',
            body => $body,
            more => 0,
        });
    }

=head1 SEE ALSO

L<PAGI::Middleware::ContentNegotiation> - chooses, refuses, and writes the
record this module reads

L<PAGI::Tools> - re-exports C<respond_to>, C<negotiated_type> and
C<content_negotiation>

L<PAGI::Request/preferred_type> - negotiating by hand where there is no
middleware

RFC 9110 Section 12 - Content Negotiation

=head1 AUTHOR

PAGI Contributors

=cut

1;
