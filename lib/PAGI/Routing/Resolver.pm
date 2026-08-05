package PAGI::Routing::Resolver;

use strict;
use warnings;
use Carp qw(croak);
use Encode qw(encode FB_CROAK);
use PAGI::Authority ();
use PAGI::Routing::Mount ();
use PAGI::Routing::Pattern ();

sub new {
    my ($class, @args) = @_;
    croak 'resolver option list must be key/value pairs' if @args % 2;
    my %opts = @args;

    my %allowed = map { $_ => 1 } qw(routes);
    for my $key (keys %opts) {
        croak "unknown resolver option '$key'" unless $allowed{$key};
    }

    my $routes = exists $opts{routes} ? $opts{routes} : [];
    PAGI::Routing::Mount::_validate_routes($routes);

    my $self = bless {
        records              => [],
        by_name              => {},
        metadata_by_location => {},
    }, $class;

    $self->_visit($routes, '', '', [], {}, []);
    return $self;
}

sub _visit {
    my ($self, $nodes, $path_prefix, $name_prefix, $outer_names,
        $outer_constraints, $location_prefix) = @_;

    for my $index (0 .. $#$nodes) {
        my $node = $nodes->[$index];
        my @location = (@$location_prefix, $index);
        my $location_key = join '.', @location;

        if ($node->isa('PAGI::Routing::Mount')) {
            my $mount_path = $node->path eq '/' ? '' : $node->path;
            my $effective_path = $path_prefix . $mount_path;
            my $published_path = length $effective_path ? $effective_path : '/';
            $self->{metadata_by_location}{$location_key} = {
                match => {
                    kind  => 'mount',
                    route => $published_path,
                    name  => undef,
                    desc  => $node->desc,
                },
                mount => {
                    path      => $node->path,
                    namespace => $node->namespace,
                    desc      => $node->desc,
                },
                is_raw => $node->is_raw ? 1 : 0,
            };

            next if $node->is_raw;

            my ($names, $constraints) = _extend_parameters(
                $outer_names, $outer_constraints, $node, $effective_path,
            );
            my $effective_namespace = _join_name($name_prefix, $node->namespace);
            my $children = $node->routes;
            $self->_visit(
                $children,
                $effective_path,
                $effective_namespace,
                $names,
                $constraints,
                \@location,
            );
            next;
        }

        next unless $node->isa('PAGI::Routing::Route');

        my $effective_path = $path_prefix . $node->path;
        my ($names, $constraints) = _extend_parameters(
            $outer_names, $outer_constraints, $node, $effective_path,
        );
        my $declared_name = $node->name;
        my $effective_name = defined $declared_name && length $declared_name
            ? _join_name($name_prefix, $declared_name)
            : undef;

        $self->{metadata_by_location}{$location_key} = {
            match => {
                kind  => $node->kind,
                route => $effective_path,
                name  => $effective_name,
                desc  => $node->desc,
            },
            mount  => undef,
            is_raw => 0,
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
            croak "duplicate effective route name '$effective_name' for effective paths "
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

sub _join_name {
    my ($prefix, $part) = @_;
    return $prefix unless defined $part && length $part;
    return $part unless defined $prefix && length $prefix;
    return "$prefix.$part";
}

sub path_for {
    my ($self, $name, $path_params, $query_params) = @_;
    croak 'route name must be a nonempty scalar'
        unless defined $name && !ref($name) && length $name;

    my $record = $self->{by_name}{$name};
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
    chop $root_path if length($root_path) && substr($root_path, -1) eq '/'
        && length($path) && substr($path, 0, 1) eq '/';
    return $root_path . $path;
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
    return exists $self->{by_name}{$name} ? $self->{by_name}{$name}{node} : undef;
}

sub route_kind {
    my ($self, $name) = @_;
    return unless defined $name && !ref($name);
    return exists $self->{by_name}{$name} ? $self->{by_name}{$name}{kind} : undef;
}

1;

__END__

=head1 NAME

PAGI::Routing::Resolver - Effective names and reverse paths for declarative routing

=head1 DESCRIPTION

This internal routing value traverses only known inline mounts. It indexes
named leaves by their effective dot-separated names, retains their original
description objects for inspection, and renders application-relative paths.
Application mounts remain opaque.

=cut
