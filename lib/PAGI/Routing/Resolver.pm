package PAGI::Routing::Resolver;

use strict;
use warnings;
use Carp qw(croak);
use Encode qw(encode FB_CROAK);
use Scalar::Util qw(blessed refaddr);
use PAGI::Authority ();
use PAGI::Routing::Mount ();
use PAGI::Routing::Pattern ();

sub new {
    my ($class, @args) = @_;
    croak 'resolver option list must be key/value pairs' if @args % 2;
    my %opts = @args;

    my %allowed = map { $_ => 1 } qw(router routes);
    for my $key (keys %opts) {
        croak "unknown resolver option '$key'" unless $allowed{$key};
    }

    croak 'resolver requires exactly one of router or routes'
        unless (exists $opts{router}) + (exists $opts{routes}) == 1;

    if (exists $opts{router}) {
        croak 'resolver router must be a PAGI::Routing::Router'
            unless blessed($opts{router})
                && $opts{router}->isa('PAGI::Routing::Router');
    }
    else {
        PAGI::Routing::Mount::_validate_routes($opts{routes});
    }

    my $self = bless {
        records              => [],
        by_name              => {},
        namespaces           => { '/' => 1 },
        metadata_by_location => {},
    }, $class;

    if (exists $opts{router}) {
        $self->_visit_router(
            $opts{router}, '', [], [], {}, [], {},
        );
    }
    else {
        $self->_visit_nodes(
            $opts{routes}, '', [], [], {}, [], {},
        );
    }
    return $self;
}

sub _visit_router {
    my ($self, $router, $path_prefix, $address_segments, $outer_names,
        $outer_constraints, $location_prefix, $active_routers) = @_;

    my $identity = refaddr($router);
    if ($active_routers->{$identity}) {
        croak "Router cycle at URL mount ancestry '"
            . _published_path($path_prefix)
            . "' and logical namespace ancestry '"
            . _logical_namespace($address_segments) . "'";
    }

    $active_routers->{$identity} = 1;
    my $routes = $router->routes;
    PAGI::Routing::Mount::_validate_routes($routes);
    $self->_visit_nodes(
        $routes,
        $path_prefix,
        $address_segments,
        $outer_names,
        $outer_constraints,
        $location_prefix,
        $active_routers,
    );
    delete $active_routers->{$identity};
    return;
}

sub _visit_nodes {
    my ($self, $nodes, $path_prefix, $address_segments, $outer_names,
        $outer_constraints, $location_prefix, $active_routers) = @_;

    $self->{namespaces}{_logical_namespace($address_segments)} = 1;

    for my $index (0 .. $#$nodes) {
        my $node = $nodes->[$index];
        my @location = (@$location_prefix, $index);
        my $location_key = join '.', @location;

        if ($node->isa('PAGI::Routing::Mount')) {
            my $mount_path = $node->path eq '/' ? '' : $node->path;
            my $effective_path = $path_prefix . $mount_path;
            my ($names, $constraints) = _extend_parameters(
                $outer_names, $outer_constraints, $node, $effective_path,
            );
            my $logical_namespace = _logical_namespace($address_segments);
            my @child_segments = @$address_segments;
            push @child_segments, $node->namespace
                if defined $node->namespace && length $node->namespace;
            $self->{metadata_by_location}{$location_key} = {
                match => {
                    kind  => 'mount',
                    route => _published_path($effective_path),
                    name  => undef,
                    logical_namespace => $logical_namespace,
                    desc  => $node->desc,
                },
                mount => {
                    path      => $node->path,
                    namespace => $node->namespace,
                    desc      => $node->desc,
                },
                is_raw => $node->is_raw ? 1 : 0,
                source => $node,
                constraints => { %$constraints },
                location => [@location],
                logical_namespace => _logical_namespace(\@child_segments),
            };

            next if $node->is_raw;

            if (defined $node->router) {
                $self->_visit_router(
                    $node->router,
                    $effective_path,
                    \@child_segments,
                    $names,
                    $constraints,
                    \@location,
                    $active_routers,
                );
            }
            else {
                $self->_visit_nodes(
                    $node->routes,
                    $effective_path,
                    \@child_segments,
                    $names,
                    $constraints,
                    \@location,
                    $active_routers,
                );
            }
            next;
        }

        next unless $node->isa('PAGI::Routing::Route');

        my $effective_path = $path_prefix . $node->path;
        my ($names, $constraints) = _extend_parameters(
            $outer_names, $outer_constraints, $node, $effective_path,
        );
        my $declared_name = $node->name;
        my $effective_name = defined $declared_name && length $declared_name
            ? _canonical_address([@$address_segments, $declared_name])
            : undef;
        my $logical_namespace = _logical_namespace($address_segments);

        $self->{metadata_by_location}{$location_key} = {
            match => {
                kind  => $node->kind,
                route => $effective_path,
                name  => $effective_name,
                logical_namespace => $logical_namespace,
                desc  => $node->desc,
            },
            mount  => undef,
            is_raw => 0,
            source => $node,
            constraints => { %$constraints },
            location => [@location],
            logical_namespace => $logical_namespace,
        };

        next unless defined $effective_name;

        my $pattern = PAGI::Routing::Pattern->new(
            path => $effective_path,
            mode => 'route',
            constraints => $constraints,
        );
        my $record = {
            name    => $effective_name,
            path    => $effective_path,
            kind    => $node->kind,
            desc    => $node->desc,
            node    => $node,
            pattern => $pattern,
        };

        if (my $previous = $self->{by_name}{$effective_name}) {
            croak "duplicate canonical route address '$effective_name' for effective paths "
                . "'$previous->{path}' and '$effective_path'; add or change a namespace";
        }

        push @{$self->{records}}, $record;
        $self->{by_name}{$effective_name} = $record;
    }
}

sub _metadata_for_location {
    my ($self, $location) = @_;
    croak 'resolver metadata location must be an arrayref'
        unless ref($location) eq 'ARRAY';

    my $record = $self->{metadata_by_location}{join '.', @$location};
    croak 'resolver metadata location is unknown' unless $record;

    return {
        match  => { %{$record->{match}} },
        mount  => defined $record->{mount} ? { %{$record->{mount}} } : undef,
        is_raw => $record->{is_raw},
        logical_namespace => $record->{logical_namespace},
    };
}

sub _extend_parameters {
    my ($outer_names, $outer_constraints, $node, $effective_path) = @_;
    my @names = @$outer_names;
    my %seen = map { $_ => 1 } @names;

    for my $name (@{$node->parameters}) {
        croak "duplicate path parameter '$name' in effective path '$effective_path'"
            if $seen{$name}++;
        push @names, $name;
    }

    my %constraints = %$outer_constraints;
    my $local_constraints = $node->constraints;
    if (defined $local_constraints) {
        @constraints{keys %$local_constraints} = values %$local_constraints;
    }

    return (\@names, \%constraints);
}

sub _canonical_address {
    my ($segments) = @_;
    return '/' . join('/', @$segments);
}

sub _logical_namespace {
    my ($segments) = @_;
    return @$segments ? _canonical_address($segments) : '/';
}

sub _published_path {
    my ($path) = @_;
    return length $path ? $path : '/';
}

sub path_for {
    my ($self, $reference, @reverse_args) = @_;
    my $rendered = $self->_render_reverse(
        'path_for', $reference, [], @reverse_args,
    );
    return $rendered->{path};
}

sub reverse_for_context {
    my ($self, $operation, $scope, $reference, $root_path,
        $logical_namespace, $captures, @reverse_args) = @_;

    croak 'Context reverse operation must be path_for or url_for'
        unless defined $operation && !ref($operation)
            && ($operation eq 'path_for' || $operation eq 'url_for');
    croak "$operation requires a canonical logical namespace"
        unless _is_canonical_namespace($logical_namespace);
    croak "$operation requires a capture hash"
        unless ref($captures) eq 'HASH';

    my @base_segments = $logical_namespace eq '/'
        ? ()
        : split(m{/}, substr($logical_namespace, 1), -1);
    my $rendered = $self->_render_reverse_from_context(
        $operation,
        $reference,
        \@base_segments,
        $captures,
        @reverse_args,
    );

    return _join_root_path($root_path, $rendered->{path})
        if $operation eq 'path_for';
    return _url_for_rendered_scope($scope, $root_path, $rendered);
}

sub url_for_scope {
    my ($self, $scope, $reference, $root_path, @reverse_args) = @_;
    my $rendered = $self->_render_reverse(
        'url_for', $reference, [], @reverse_args,
    );
    return _url_for_rendered_scope($scope, $root_path, $rendered);
}

sub _url_for_rendered_scope {
    my ($scope, $root_path, $rendered) = @_;
    my $kind = $rendered->{record}{kind};
    my $scope_scheme = defined $scope->{scheme} ? $scope->{scheme} : 'http';
    croak 'unsupported URL scheme'
        if ref($scope_scheme) || $scope_scheme !~ /\A(?:http|https|ws|wss)\z/;

    my $url_scheme;
    if ($kind eq 'websocket') {
        my %scheme_for = (
            http => 'ws', https => 'wss', ws => 'ws', wss => 'wss',
        );
        $url_scheme = $scheme_for{$scope_scheme};
    }
    else {
        my %scheme_for = (
            http => 'http', https => 'https', ws => 'http', wss => 'https',
        );
        $url_scheme = $scheme_for{$scope_scheme};
    }

    my $authority = PAGI::Authority->from_scope($scope);
    my $path = _join_root_path($root_path, $rendered->{path});
    return "$url_scheme://$authority$path";
}

sub _render_reverse {
    my ($self, $operation, $reference, $base_segments, @reverse_args) = @_;
    my $arguments = _parse_reverse_arguments($operation, @reverse_args);
    my ($canonical, $was_absolute, $ended_with_navigation) = _normalize_reference(
        $operation, $reference, $base_segments,
    );

    croak "$operation route reference '$reference' resolves to a logical namespace, not a route"
        if $ended_with_navigation;
    my $record = $self->{by_name}{$canonical};
    croak "$operation route reference '$reference' resolves to a logical namespace, not a route"
        if !$record && $self->{namespaces}{$canonical};
    croak "$operation unknown route name '$reference'" unless $record;

    return $self->_render_resolved_reverse(
        $arguments, $record, $canonical, $was_absolute,
    );
}

sub _render_reverse_from_context {
    my ($self, $operation, $reference, $base_segments, $captures,
        @reverse_args) = @_;
    my $arguments = _parse_reverse_arguments($operation, @reverse_args);
    my ($canonical, $was_absolute, $ended_with_navigation) = _normalize_reference(
        $operation, $reference, $base_segments,
    );

    croak "$operation route reference '$reference' resolves to a logical namespace, not a route"
        if $ended_with_navigation;
    my $record = $self->{by_name}{$canonical};
    croak "$operation route reference '$reference' resolves to a logical namespace, not a route"
        if !$record && $self->{namespaces}{$canonical};
    croak "$operation unknown route name '$reference'" unless $record;

    if (!$was_absolute) {
        my %inherited;
        for my $name (@{$record->{pattern}->parameters}) {
            $inherited{$name} = $captures->{$name}
                if exists $captures->{$name};
        }
        $arguments->{params} = {
            %inherited,
            %{$arguments->{params}},
        };
    }

    return $self->_render_resolved_reverse(
        $arguments, $record, $canonical, $was_absolute,
    );
}

sub _render_resolved_reverse {
    my ($self, $arguments, $record, $canonical, $was_absolute) = @_;
    my $path = $record->{pattern}->render($arguments->{params}, $canonical);
    my @pairs;
    for my $key (sort keys %{$arguments->{query}}) {
        my $value = $arguments->{query}{$key};
        croak "query parameter '$key' must be a scalar" if ref($value);
        $value = '' unless defined $value;
        push @pairs, _encode_component($key) . '=' . _encode_component($value);
    }
    $path .= '?' . join('&', @pairs) if @pairs;
    $path .= '#' . _encode_component($arguments->{fragment})
        if $arguments->{has_fragment};

    return {
        record       => $record,
        canonical    => $canonical,
        was_absolute => $was_absolute,
        path          => $path,
    };
}

sub _parse_reverse_arguments {
    my ($operation, @args) = @_;
    my $result = {
        params       => {},
        query        => {},
        has_fragment => 0,
        fragment     => undef,
    };
    return $result unless @args;

    my %allowed = map { $_ => 1 } qw(params query fragment);
    if (ref($args[0]) eq 'HASH') {
        if (@args >= 3) {
            for my $index (1 .. $#args - 1) {
                next unless defined $args[$index] && !ref($args[$index]);
                croak "$operation reverse-routing compact and named reverse-routing forms cannot be mixed"
                    if $allowed{$args[$index]};
            }
        }
        croak "$operation reverse-routing compact form accepts at most params, query, and fragment"
            if @args > 3;
        croak "$operation reverse-routing compact query must be a hashref"
            if @args >= 2 && ref($args[1]) ne 'HASH';
        croak "$operation reverse-routing compact fragment must be a plain scalar or undef"
            if @args >= 3 && defined $args[2] && ref($args[2]);

        $result->{params} = { %{$args[0]} };
        $result->{query} = { %{$args[1]} } if @args >= 2;
        if (@args >= 3 && defined $args[2]) {
            $result->{has_fragment} = 1;
            $result->{fragment} = $args[2];
        }
        return $result;
    }

    croak "$operation reverse-routing form selector must be a hashref or named option key"
        unless defined $args[0] && !ref($args[0]);
    croak "$operation reverse-routing named option list must contain key/value pairs"
        if @args % 2;

    my %options;
    while (@args) {
        my ($key, $value) = splice @args, 0, 2;
        croak "$operation reverse-routing unknown named option 'reference'"
            unless defined $key && !ref($key);
        croak "$operation reverse-routing unknown named option '$key'"
            unless $allowed{$key};
        $options{$key} = $value;
    }

    croak "$operation reverse-routing named params must be a hashref"
        if exists $options{params} && ref($options{params}) ne 'HASH';
    croak "$operation reverse-routing named query must be a hashref"
        if exists $options{query} && ref($options{query}) ne 'HASH';
    croak "$operation reverse-routing named fragment must be a plain scalar or undef"
        if exists $options{fragment}
            && defined $options{fragment} && ref($options{fragment});

    $result->{params} = { %{$options{params}} } if exists $options{params};
    $result->{query} = { %{$options{query}} } if exists $options{query};
    if (exists $options{fragment} && defined $options{fragment}) {
        $result->{has_fragment} = 1;
        $result->{fragment} = $options{fragment};
    }
    return $result;
}

sub _normalize_reference {
    my ($operation, $reference, $base_segments) = @_;
    croak "$operation route reference must be a nonempty scalar"
        unless defined $reference && !ref($reference) && length $reference;
    croak "$operation route reference base must be an arrayref"
        unless ref($base_segments) eq 'ARRAY';

    my $was_absolute = substr($reference, 0, 1) eq '/' ? 1 : 0;
    my @segments = $was_absolute ? () : @$base_segments;
    my $spelling = $was_absolute ? substr($reference, 1) : $reference;
    my @input = length($spelling) ? split(m{/}, $spelling, -1) : ();
    my $ended_with_navigation = @input
        && ($input[-1] eq '.' || $input[-1] eq '..') ? 1 : 0;

    for my $segment (@input) {
        croak "$operation route reference '$reference' contains an empty logical segment"
            unless length $segment;
        next if $segment eq '.';
        if ($segment eq '..') {
            croak "$operation route reference '$reference' traverses above the Router root"
                unless @segments;
            pop @segments;
            next;
        }
        push @segments, $segment;
    }

    return (_canonical_address(\@segments), $was_absolute, $ended_with_navigation);
}

sub _is_canonical_namespace {
    my ($namespace) = @_;
    return 0 unless defined $namespace && !ref($namespace);
    return 1 if $namespace eq '/';
    return 0 unless length($namespace) > 1
        && substr($namespace, 0, 1) eq '/'
        && substr($namespace, -1) ne '/';

    my @segments = split(m{/}, substr($namespace, 1), -1);
    for my $segment (@segments) {
        return 0 unless length $segment;
        return 0 if $segment eq '.' || $segment eq '..';
    }
    return 1;
}

sub _join_root_path {
    my ($root_path, $path) = @_;
    $root_path = '' unless defined $root_path;
    $root_path = _encode_path($root_path);
    my $suffix = '';
    if ($path =~ /([?#])/) {
        my $boundary = index($path, $1);
        $suffix = substr($path, $boundary);
        $path = substr($path, 0, $boundary);
    }
    chop $root_path if length($root_path) && substr($root_path, -1) eq '/'
        && length($path) && substr($path, 0, 1) eq '/';
    return $root_path . $path . $suffix;
}

sub _encode_path {
    my ($value) = @_;
    my $bytes = encode('UTF-8', $value, FB_CROAK);
    $bytes =~ s{([^A-Za-z0-9\-._~/])}{sprintf('%%%02X', ord($1))}ge;
    return $bytes;
}

sub _encode_component {
    my ($value) = @_;
    my $bytes = encode('UTF-8', $value, FB_CROAK);
    $bytes =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge;
    return $bytes;
}

sub named_routes {
    my ($self) = @_;
    return { map { $_->{name} => $_->{node} } @{$self->{records}} };
}

sub route_named {
    my ($self, $reference) = @_;
    my ($name, $was_absolute, $ended_with_navigation);
    {
        local $@;
        return unless eval {
            ($name, $was_absolute, $ended_with_navigation)
                = _normalize_reference('route_named', $reference, []);
            1;
        };
    }

    return if $ended_with_navigation;
    return exists $self->{by_name}{$name} ? $self->{by_name}{$name}{node} : undef;
}

sub route_kind {
    my ($self, $name) = @_;
    return unless defined $name && !ref($name);
    $name = _root_reference($name);
    return exists $self->{by_name}{$name} ? $self->{by_name}{$name}{kind} : undef;
}

sub _root_reference {
    my ($name) = @_;
    return $name if !length($name) || substr($name, 0, 1) eq '/';
    return "/$name";
}

1;

__END__

=head1 NAME

PAGI::Routing::Resolver - Composed slash addresses and reverse paths

=head1 DESCRIPTION

This internal routing value traverses direct routes, inline mounts, and
explicit C<< router => $router >> children. It indexes named leaves by
canonical absolute slash addresses, retains each original leaf identity for
inspection, and renders application-relative paths for the outer placement.
Positional application mounts remain opaque, including positional Router
targets.

Construction validates/builds the effective address, path, constraint, and
location index once and does no request I/O. Every known mount prefix is
validated before opacity ends traversal. Duplicate canonical addresses report
both effective paths, and a path parameter may occur only once along one
ancestor-to-descendant effective path. Router identity is tracked only in the
active ancestry, rejecting cycles while allowing sibling placement reuse.

Child Router descriptions remain placement-free: traversal calls their
C<routes> method and never reuses their local resolver as an outer placement
resolver. Reverse arguments use one parser for Router C<path_for>, Context
C<path_for>, and Context C<url_for>. The compact and named forms are:

    path_for($reference, \%params, \%query, $fragment)
    path_for($reference,
        params => \%params, query => \%query, fragment => $fragment)

No arguments means empty params/query and no fragment. A first trailing
hashref selects compact form; a first trailing defined plain scalar selects
named form. Other selectors fail, and compact and named forms cannot be mixed.
Compact query-only and fragment-only calls retain empty placeholders:

    path_for('/index', {}, { q => 'two words' })
    path_for('/index', {}, {}, 'details')

Explicit C<undef> omits a fragment, while an empty fragment emits a terminal
C<#>. Params and query values are copied during parsing. Query keys are sorted
and query components are UTF-8 percent-encoded; the fragment is UTF-8 encoded
as one component after the query.

C<path_for> validates values and returns an application-relative string.
C<url_for_scope> additionally reads one request scope, delegates authority to
L<PAGI::Authority>, applies the compiled-router C<root_path> boundary, and
returns an absolute string. It resolves the target once and maps the indexed
route kind to the URL scheme; for example, suffix ordering is
C<https://example.test/items/7?q=two%20words#details> for HTTP/SSE and
C<wss://example.test/socket/7?q=two%20words#details> for WebSocket. Neither
reverse method invokes receive/send callbacks or emits protocol events. The decoded Unicode boundary
is escaped component-wise before it is joined to the already escaped generated
path. Both return a string or croak; neither redirects or mutates a response.
Matched leaf metadata includes its effective URL pattern, canonical
address, containing logical namespace, kind, and description. Placement
records retain the source leaf, mount data, composed constraints, and defensive
location information. References beginning with C</> are absolute; other
references resolve from an explicit logical base (the Router root for public
Router reverse calls). Components C<.> and C<..> normalize left-to-right,
while dots inside a component remain literal. Empty components, repeated or
trailing separators, traversal above root, and namespace-only results fail.
References are never URI-decoded and lookup is exact: there is no ancestor
search, absolute retry, prefix folding, or dotted hierarchy. C<named_routes>
returns a defensive hashref, while C<route_named>
preserves the original leaf identity and C<route_kind> returns the immutable
indexed kind.

C<reverse_for_context> is the Context-only request-aware entry point. It
parses one reverse argument list, resolves one exact target from the frame's
canonical C<logical_namespace>, and renders that resolved record once. Only
relative spellings select target-required keys from the frame's capture
snapshot before explicit params are overlaid. Absolute Context references and
all public Router calls remain inheritance-free. Query and fragment values are
never read from captures. The existing Pattern renderer remains responsible
for missing, extra, scalar, and constraint validation. URL mode adds the
request scheme and L<PAGI::Authority> only after target resolution; neither
mode performs protocol I/O.

Relative capture inheritance is a URL-construction convenience. It does not
authorize the generated target; handlers remain responsible for access checks.

=cut
