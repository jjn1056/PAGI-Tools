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
            };

            next if $node->is_raw;

            my @child_segments = @$address_segments;
            push @child_segments, $node->namespace
                if defined $node->namespace && length $node->namespace;

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
    my ($self, $name, $path_params, $query_params) = @_;
    croak 'route name must be a nonempty scalar'
        unless defined $name && !ref($name) && length $name;

    my $record = $self->{by_name}{_root_reference($name)};
    croak "unknown route name '$name'" unless $record;

    $path_params = {} unless defined $path_params;
    $query_params = {} unless defined $query_params;

    my $path = $record->{pattern}->render($path_params, $name);
    croak "query parameters for route '$name' must be a hashref"
        unless ref($query_params) eq 'HASH';

    my @pairs;
    for my $key (sort keys %$query_params) {
        my $value = $query_params->{$key};
        croak "query parameter '$key' must be a scalar" if ref($value);
        $value = '' unless defined $value;
        push @pairs, _encode_component($key) . '=' . _encode_component($value);
    }

    return @pairs ? $path . '?' . join('&', @pairs) : $path;
}

sub url_for_scope {
    my ($self, $scope, $name, $path_params, $query_params, $root_path) = @_;
    my $has_root_path = @_ >= 6;
    my $path = $self->path_for($name, $path_params, $query_params);
    my $kind = $self->route_kind($name);
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
    $root_path = $scope->{root_path} unless $has_root_path;
    $path = _join_root_path($root_path, $path);
    return "$url_scheme://$authority$path";
}

sub _join_root_path {
    my ($root_path, $path) = @_;
    $root_path = '' unless defined $root_path;
    $root_path = _encode_path($root_path);
    chop $root_path if length($root_path) && substr($root_path, -1) eq '/'
        && length($path) && substr($path, 0, 1) eq '/';
    return $root_path . $path;
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
    my ($self, $name) = @_;
    return unless defined $name && !ref($name);
    $name = _root_reference($name);
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
resolver. C<path_for> validates path/query values and returns a string.
C<url_for_scope> additionally reads one request scope, delegates authority to
L<PAGI::Authority>, applies the compiled-router C<root_path> boundary, and
returns an absolute string; it emits no events. The decoded Unicode boundary
is escaped component-wise before it is joined to the already escaped generated
path. Matched leaf metadata includes its effective URL pattern, canonical
address, containing logical namespace, kind, and description. Placement
records retain the source leaf, mount data, composed constraints, and defensive
location information. References beginning with C</> are absolute; bare and
child-slash references resolve from the current Router root by adding one
leading slash. Dots remain literal within one segment and never spell logical
hierarchy. C<named_routes> returns a defensive hashref, while C<route_named>
preserves the original leaf identity and C<route_kind> returns the immutable
indexed kind.

=cut
