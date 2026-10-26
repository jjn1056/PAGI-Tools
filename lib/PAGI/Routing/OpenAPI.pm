package PAGI::Routing::OpenAPI;

use strict;
use warnings;
use Carp qw(croak);
use Exporter qw(import);
use Scalar::Util qw(blessed);
use PAGI::Compose ();
use PAGI::Response::JSON ();
use PAGI::Routing ();

our @EXPORT_OK = qw(openapi openapi_document);

my %OPTION = map { $_ => 1 } qw(title version description security_scheme components path);

# The operations an OpenAPI 3.1 path item can hold. A route method outside
# them (QUERY, a custom token) has no field to go in and is left out.
my %OPERATION = map { $_ => 1 } qw(get put post delete options head patch trace);

# The JSON Schema type of the Types::Standard types a capture is commonly
# declared with. A type derived from one maps as that one does.
my %JSON_TYPE = (Int => 'integer', Num => 'number', Str => 'string', Bool => 'boolean');

# How a middleware('Requires', ...) description names its factory.
my %REQUIRES = map { $_ => 1 } qw(Requires PAGI::Middleware::Requires +PAGI::Middleware::Requires);

# Built for each operation, so no two operations or documents share it.
sub _sse_responses {
    return {
        200 => {
            description => 'An event stream',
            content     => { 'text/event-stream' => { schema => { type => 'string' } } },
        },
    };
}

sub openapi {
    my ($source, @options) = @_;
    return __PACKAGE__->new(@options)->apply($source);
}

sub openapi_document {
    my ($source, @options) = @_;
    return __PACKAGE__->new(@options)->document($source);
}

sub new {
    my ($class, @args) = @_;
    croak 'PAGI::Routing::OpenAPI: options must be key/value pairs' if @args % 2;
    my %opts = @args;
    for my $key (sort keys %opts) {
        croak "PAGI::Routing::OpenAPI: unknown option '$key'" unless $OPTION{$key};
    }
    for my $key (qw(title version)) {
        croak "PAGI::Routing::OpenAPI: $key is required"
            unless defined $opts{$key} && !ref $opts{$key} && length $opts{$key};
        # OpenAPI requires strings: version => 1 must not encode as a number.
        $opts{$key} = "$opts{$key}";
    }
    if (exists $opts{security_scheme}) {
        my $scheme = $opts{security_scheme};
        croak 'PAGI::Routing::OpenAPI: security_scheme must be [name => \%scheme]'
            unless ref($scheme) eq 'ARRAY' && @$scheme == 2
                && defined($scheme->[0]) && !ref($scheme->[0]) && length($scheme->[0])
                && ref($scheme->[1]) eq 'HASH';
    }
    croak 'PAGI::Routing::OpenAPI: components must be a hashref'
        if exists $opts{components} && ref($opts{components}) ne 'HASH';
    $opts{path} = '/openapi.json' unless defined $opts{path};
    croak 'PAGI::Routing::OpenAPI: path must be a path starting with /'
        if ref($opts{path}) || $opts{path} !~ m{\A/};
    return bless {%opts}, $class;
}

sub document {
    my ($self, $source) = @_;
    croak 'PAGI::Routing::OpenAPI: document needs an application with route_table (a Compose or a Router)'
        unless blessed($source) && $source->can('route_table');

    my (%paths, %template_of_shape, %operation_ids);
    for my $entry ($source->route_table) {
        my $kind = $entry->kind;
        next unless $kind eq 'route' || $kind eq 'sse';
        my $template = $entry->template;

        # OpenAPI forbids two paths differing only in their parameter names,
        # and a path holds one operation per method.
        (my $shape = $template) =~ s/\{[^}]*\}/{}/g;
        croak "PAGI::Routing::OpenAPI: $template and $template_of_shape{$shape} are the same OpenAPI path"
            if exists $template_of_shape{$shape} && $template_of_shape{$shape} ne $template;
        $template_of_shape{$shape} = $template;

        for my $method (_methods($entry)) {
            croak "PAGI::Routing::OpenAPI: two routes for $method $template"
                if $paths{$template}{ lc $method };
            my $operation = $self->_operation($entry, $method);
            my $id = $operation->{operationId};
            croak "PAGI::Routing::OpenAPI: operationId $id is not unique"
                if defined $id && $operation_ids{$id}++;
            $paths{$template}{ lc $method } = $operation;
        }
    }

    my %info = (title => $self->{title}, version => $self->{version});
    $info{description} = $self->{description} if defined $self->{description};
    my %document = (openapi => '3.1.0', info => \%info, paths => \%paths);

    my %components = %{ $self->{components} || {} };
    if (my $scheme = $self->{security_scheme}) {
        $components{securitySchemes} = { %{ $components{securitySchemes} || {} }, $scheme->[0] => $scheme->[1] };
    }
    $document{components} = \%components if %components;
    return \%document;
}

sub apply {
    my ($self, $source) = @_;
    my $is_compose = blessed($source) && $source->isa('PAGI::Compose');
    my $router = $is_compose ? $source->router
        : blessed($source) && $source->isa('PAGI::Routing::Router') ? $source
        : undef;
    croak 'PAGI::Routing::OpenAPI: openapi needs a PAGI::Compose or a PAGI::Routing::Router'
        unless $router;

    # Built now, so a document that cannot be built fails at startup, and
    # from the source, so it never lists its own route.
    my $document = $self->document($source);
    my $path     = $self->{path};
    croak "PAGI::Routing::OpenAPI: the application answers GET $path, which the document route would shadow;"
        . ' give openapi another path'
        if exists $document->{paths}{$path} && $document->{paths}{$path}{get};

    my $serve = sub {
        my ($request) = @_;
        # Served under a prefix (behind a proxy, or mounted), the paths are
        # relative to it: servers says where.
        my $root = $request->scope->{root_path};
        $root = '' unless defined $root;
        return PAGI::Response::JSON->new(length $root ? { %$document, servers => [{ url => $root }] } : $document);
    };

    # The document is a route of the application: its middleware (CORS,
    # logging, error handling) and Compose's HEAD handling apply to it. The
    # source's root Router, mounted behind it, keeps its names, its
    # http_default and its desc.
    my $lifespan     = $is_compose ? $source->lifespan : undef;
    my $desc         = $router->desc;
    # Never consulted: the root mount matches every path, so misses reach the
    # source Router's own. Carried so the result reports what it answers.
    my $http_default = $router->http_default;
    return PAGI::Compose->new(
        routes => [
            PAGI::Routing::route($path => $serve, methods => ['GET']),
            PAGI::Routing::mount('/' => app => $router),
        ],
        ($is_compose        ? (middleware => $source->middleware) : ()),
        (defined $lifespan  ? (lifespan   => $lifespan)           : ()),
        (defined $desc      ? (desc       => $desc)               : ()),
        (defined $http_default ? (http_default => $http_default) : ()),
    );
}

sub operation_id {
    my ($self, $entry, $method) = @_;
    my $base = defined $entry->address ? $entry->address : $entry->template;
    (my $id = lc($method) . $base) =~ s/[^A-Za-z0-9]+/_/g;
    $id =~ s/\A_+//;
    $id =~ s/_+\z//;
    return $id;
}

sub parameter_schema {
    my ($self, $name, @constraints) = @_;
    for my $type (grep { blessed($_) && $_->can('display_name') } @constraints) {
        for (my $t = $type; $t; $t = $t->can('parent') ? $t->parent : undef) {
            my $json = $JSON_TYPE{ $t->display_name };
            return { type => $json } if defined $json;
        }
    }
    return { type => 'string' };
}

sub security_for {
    my ($self, $entry) = @_;
    my ($found, %scopes);
    for my $description (@{ $entry->middleware }) {
        my $factory = $description->factory;
        next unless defined $factory && !ref $factory && $REQUIRES{$factory};
        $found = 1;
        # The description holds scopes as declared: a string is one scope,
        # none at all means any authenticated user.
        my $declared = $description->config->{scopes};
        $scopes{$_} = 1 for !defined $declared ? () : ref $declared eq 'ARRAY' ? @$declared : ($declared);
    }
    return undef unless $found;
    croak 'PAGI::Routing::OpenAPI: routes use Requires; give a security_scheme'
        unless $self->{security_scheme};
    return [{ $self->{security_scheme}[0] => [sort keys %scopes] }];
}

sub operation {
    my ($self, $entry, $method, $operation) = @_;
    return $operation;
}

sub _methods {
    my ($entry) = @_;
    return ('GET') if $entry->kind eq 'sse';
    my $declared = $entry->methods;
    my @methods = ref $declared eq 'ARRAY' ? @$declared : ('GET');
    my %has = map { $_ => 1 } @methods;
    return grep { $OPERATION{ lc $_ } && !($_ eq 'HEAD' && $has{GET}) } @methods;
}

sub _operation {
    my ($self, $entry, $method) = @_;
    my %operation;
    my $id = $self->operation_id($entry, $method);
    $operation{operationId} = $id if defined $id;
    $operation{summary} = $entry->desc if defined $entry->desc;

    my $constraints = $entry->constraints;
    my @parameters = map {
        +{
            name     => $_,
            in       => 'path',
            required => \1,
            schema   => $self->parameter_schema($_, @{ $constraints->{$_} || [] }),
        }
    } @{ $entry->parameters };

    my $security = $self->security_for($entry);
    $operation{security} = $security if $security;

    # Each level's hand-written fragment, outermost first, so a route's
    # overrides its mount's. Parameters merge by name and location.
    for my $level (@{ $entry->meta }) {
        next unless exists $level->{openapi};
        my $fragment = $level->{openapi};
        croak 'PAGI::Routing::OpenAPI: ' . $entry->template . "'s meta openapi must be a hashref"
            unless ref $fragment eq 'HASH';
        for my $key (sort keys %$fragment) {
            if ($key eq 'parameters') {
                @parameters = _merge_parameters($entry, \@parameters, $fragment->{parameters});
            }
            else {
                $operation{$key} = $fragment->{$key};
            }
        }
    }
    $operation{parameters} = \@parameters if @parameters;
    $operation{responses} = $entry->kind eq 'sse' ? _sse_responses() : { default => { description => 'response' } }
        unless exists $operation{responses};
    return $self->operation($entry, $method, \%operation);
}

sub _merge_parameters {
    my ($entry, $parameters, $given) = @_;
    croak 'PAGI::Routing::OpenAPI: ' . $entry->template . "'s meta openapi parameters must be an arrayref"
        unless ref $given eq 'ARRAY';
    my @merged = @$parameters;
    for my $parameter (@$given) {
        # A reference to components.parameters names no parameter here.
        if (ref $parameter eq 'HASH' && exists $parameter->{'$ref'}) { push @merged, $parameter; next }
        croak 'PAGI::Routing::OpenAPI: ' . $entry->template . "'s meta openapi parameters must be hashrefs with name and in"
            unless ref $parameter eq 'HASH' && defined $parameter->{name} && defined $parameter->{in};
        my ($index) = grep {
            $merged[$_]{name} eq $parameter->{name} && $merged[$_]{in} eq $parameter->{in}
        } 0 .. $#merged;
        if (defined $index) { $merged[$index] = { %{ $merged[$index] }, %$parameter } }
        else                { push @merged, $parameter }
    }
    return @merged;
}

1;

__END__

=head1 NAME

PAGI::Routing::OpenAPI - an OpenAPI document from an application's routes

=head1 SYNOPSIS

    use PAGI::Tools qw(compose route openapi);

    # The application with its document as a route: GET /openapi.json
    # answers with it, inside the application's own middleware.
    my $app = openapi(compose(routes => [...]), title => 'Notes', version => '1.0.0');

    # Just the document, for a framework or a test.
    use PAGI::Routing::OpenAPI qw(openapi_document);
    my $doc = openapi_document($compose, title => 'Notes', version => '1.0.0');

    # Building on it: override one of the documented methods.
    package MyFramework::OpenAPI {
        use parent 'PAGI::Routing::OpenAPI';
        sub operation {
            my ($self, $entry, $method, $operation) = @_;
            $operation->{tags} //= ['api'];
            return $operation;
        }
    }

=head1 DESCRIPTION

B<Early beta.> This module is new, and its interface -- C<openapi>'s options,
how a route's C<meta> describes its bodies, and the overridable methods -- may
still change in an incompatible way in a later release. Pin the version you
build on, and expect to revisit your C<meta> when you upgrade.

An OpenAPI 3.1.0 document built from an application's
L<route_table|PAGI::Routing::RouteEntry>: its paths and methods, typed path
parameters, operationIds, summaries from each route's C<desc>, security from
L<PAGI::Middleware::Requires>, and whatever each route and mount declares
under C<< meta => { openapi => {...} } >> -- request and response bodies,
chiefly. Nothing is validated or derived from code; what the routes do not
say, the document does not either.

A mounted application other than a Router is a separate application (see
L<PAGI::Routing/mount>) and is not described: it describes itself.

=head1 FUNCTIONS

Both are exportable; C<openapi> is also re-exported by L<PAGI::Tools>.

=head2 openapi

    my $app = openapi($compose, title => 'Notes', version => '1.0.0');

C<< PAGI::Routing::OpenAPI->new(%options)->apply($compose) >>: the
application, a new L<PAGI::Compose>, with its document as a route. For a
small application in one script this is the whole of it. A
L<PAGI::App::Compose> calls it in its C<application> hook:

    sub application ($self, $composition) {
        return openapi($composition, title => 'Notes', version => '1.0.0');
    }

=head2 openapi_document

    my $doc = openapi_document($compose, title => 'Notes', version => '1.0.0');

C<< PAGI::Routing::OpenAPI->new(%options)->document($source) >>: the
document as a Perl hashref.

=head1 CONSTRUCTOR

=head2 new

    my $openapi = PAGI::Routing::OpenAPI->new(
        title           => 'Notes',                 # info.title, required
        version         => '1.0.0',                 # info.version, required
        description     => 'Notes for a small team', # info.description
        security_scheme => [bearer => { type => 'http', scheme => 'bearer' }],
        components      => { schemas => { Note => {...} } },
        path            => '/openapi.json',         # the document route's path
    );

C<security_scheme> is the one scheme a C<Requires> maps to, placed in
C<components.securitySchemes>; it is required when any route has a
C<Requires>. C<components> is merged into the document's C<components> --
C<schemas> for C<$ref> targets, chiefly, which a client generator turns into
named models. An unknown option, or a missing C<title> or C<version>, dies.

=head1 METHODS

=head2 document

    my $doc = $openapi->document($source);

The document for C<$source>, anything with C<route_table> (a
L<PAGI::Compose> or a L<PAGI::Routing::Router>), as a hashref. Values taken
from C<meta> are the originals, not copies.

=head2 apply

    my $app = $openapi->apply($compose);

Takes a L<PAGI::Compose> or a L<PAGI::Routing::Router> and returns a new
Compose: a C<GET> route at C<path> answering with the document as JSON, and
the source's root Router mounted at C</> behind it, with a Compose source's
application middleware and lifespan carried over. Its names, C<path_for>,
C<http_default> and C<desc> are the source's. The document is built now, from
the source, so a document that cannot be built fails at startup and it never
lists its own route. A request with a non-empty C<root_path> gets
C<< servers => [{ url => $root_path }] >> added.

The document route is a route of the application, so the application's own
middleware -- CORS, logging, error handling -- and Compose's HEAD handling
apply to it. A refusing application middleware (an Authentication that
turns guests away) refuses the document too; to keep it public, put that
middleware on a Router or a mount instead.

Dies when the source declares a C<GET> route at exactly C<path>, which the
document route would shadow. A capture or wildcard route that would also match
C<path> (C</{file}>, C</*rest>) is not detected: the document route, declared
first, answers there. The result is a Compose, so it can be inspected and
passed to another function that takes one.

=head1 THE DOCUMENT

=over 4

=item * B<Kinds.> Route entries become operations. An SSE route is a C<get>
whose default response is a C<200> of C<text/event-stream>. WebSocket routes
and mounted applications are left out.

=item * B<Methods.> C<HEAD> is left out where C<GET> answers it, and kept
for a HEAD-only route. An unrestricted route (C<< methods => '*' >>) is a
C<get>. A method that is not an OpenAPI 3.1 operation (C<QUERY>, a custom
token) is left out.

=item * B<Collisions> die: two templates differing only in parameter names
(C</items/{id}> and C</items/{slug}>), or two routes for one method and
template.

=item * B<operationId> (L</operation_id>): the method and the route's
address, or its template when it has no name, each run of other characters
an underscore (C<get_notes_show>, C<get_health>). A C<meta> C<operationId>
replaces it. A duplicate dies.

=item * B<summary> is the route's C<desc>.

=item * B<Path parameters> (L</parameter_schema>): one per capture, required,
with a schema from its constraints.

=item * B<security> (L</security_for>): from each C<Requires> on the route.

=item * B<meta>: each level's C<< meta->{openapi} >> is merged into the
operation, outermost first, key by key, so a route's fragment overrides its
mount's. C<parameters> merge by C<name> and C<in>: a fragment parameter that
matches a generated one replaces those keys of it (its C<schema>, say);
others, and C<$ref>s to C<components.parameters>, are appended, which is how
query parameters are declared.

=item * B<responses>, when nothing gives them:
C<< { default => { description => 'response' } } >>. Declare responses in
C<meta> for a client generator to produce typed results.

=back

An operation with no parameters or no security has no C<parameters> or
C<security> key.

=head1 OVERRIDABLE METHODS

=head2 operation_id

    my $id = $self->operation_id($entry, $method);

The default described above. Returning undef leaves the operation without
one.

=head2 parameter_schema

    my $schema = $self->parameter_schema($name, @constraints);

The JSON Schema for a path parameter, from its constraints as declared (see
L<PAGI::Routing::RouteEntry/constraints>). The default walks each constraint
that has C<display_name> (a L<Type::Tiny> type, say) and its C<parent>s for
C<Int>, C<Num>, C<Str> or C<Bool>, giving C<integer>, C<number>, C<string> or
C<boolean>; anything else, a Regexp included, is a C<string>, with no
C<pattern> (a Perl regexp is not always a valid ECMA one). Type::Tiny is
never loaded.

=head2 security_for

    my $security = $self->security_for($entry);

The operation's C<security>, or undef for none. The default finds each
C<middleware('Requires', ...)> description in the entry's C<middleware> --
the route's, its mounts' and Routers', and Compose's application middleware
-- and gives C<< [{ $scheme => [@scopes] }] >>, the scopes of all of them,
unique and sorted (none for a C<Requires> without scopes: any authenticated
user). A C<Requires> given as a configured object is not recognized. It dies
when there is a C<Requires> and no C<security_scheme>.

=head2 operation

    my $operation = $self->operation($entry, $method, \%operation);

The last word on each operation, after C<meta> is merged: returns the
operation hashref. The default returns it unchanged.

=head1 SEE ALSO

L<PAGI::Routing::RouteEntry>, L<PAGI::Middleware::Requires>, L<PAGI::Routing>

=cut
