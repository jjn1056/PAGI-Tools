package PAGI::App::Router::Builder;

use strict;
use warnings;
use Carp qw(croak);
use PAGI::Routing::Middleware ();
use PAGI::Routing::Route ();

sub new {
    my ($class, @args) = @_;
    my $opts = _option_hash('router', @args);

    my %allowed = map { $_ => 1 }
        qw(desc middleware not_found method_not_allowed);
    for my $key (keys %$opts) {
        croak "unknown router option '$key'" unless $allowed{$key};
    }

    PAGI::Routing::Route::_validate_text('desc', $opts->{desc}, 0)
        if exists $opts->{desc};
    for my $name (qw(not_found method_not_allowed)) {
        croak "$name must be a coderef"
            if exists $opts->{$name} && ref($opts->{$name}) ne 'CODE';
    }

    my $middleware = PAGI::Routing::Middleware->_normalize_descriptors(
        exists $opts->{middleware} ? $opts->{middleware} : [],
        'middleware',
    );

    return bless {
        declarations       => [],
        desc               => $opts->{desc},
        middleware         => $middleware,
        not_found          => $opts->{not_found},
        method_not_allowed => $opts->{method_not_allowed},
    }, $class;
}

sub get {
    my ($self, @args) = @_;
    my $package = caller;
    return $self->_add_route_from($package, 'route', ['GET'], @args);
}

sub post {
    my ($self, @args) = @_;
    my $package = caller;
    return $self->_add_route_from($package, 'route', ['POST'], @args);
}

sub put {
    my ($self, @args) = @_;
    my $package = caller;
    return $self->_add_route_from($package, 'route', ['PUT'], @args);
}

sub patch {
    my ($self, @args) = @_;
    my $package = caller;
    return $self->_add_route_from($package, 'route', ['PATCH'], @args);
}

sub delete {
    my ($self, @args) = @_;
    my $package = caller;
    return $self->_add_route_from($package, 'route', ['DELETE'], @args);
}

sub head {
    my ($self, @args) = @_;
    my $package = caller;
    return $self->_add_route_from($package, 'route', ['HEAD'], @args);
}

sub options {
    my ($self, @args) = @_;
    my $package = caller;
    return $self->_add_route_from($package, 'route', ['OPTIONS'], @args);
}

sub any {
    my ($self, @args) = @_;
    my $package = caller;
    return $self->_add_route_from($package, 'route', '*', @args);
}

sub route {
    my ($self, @args) = @_;
    my $package = caller;
    return $self->_add_route_from($package, 'route', undef, @args);
}

sub websocket {
    my ($self, @args) = @_;
    my $package = caller;
    return $self->_add_route_from($package, 'websocket', undef, @args);
}

sub sse {
    my ($self, @args) = @_;
    my $package = caller;
    return $self->_add_route_from($package, 'sse', undef, @args);
}

sub _add_route_from {
    my ($self, $package, $kind, $methods, $path, @args) = @_;

    croak 'route path must be a string' unless defined $path && !ref($path);

    my $middleware = [];
    if (@args && ref($args[0]) eq 'ARRAY') {
        $middleware = shift @args;
    }

    croak 'route requires a target' unless @args;

    my ($target, $is_raw);
    if (defined $args[0] && !ref($args[0]) && $args[0] eq 'raw') {
        shift @args;
        croak 'raw target must be defined' unless @args && defined $args[0];
        $target = shift @args;
        $is_raw = 1;
    }
    else {
        $target = shift @args;
        croak 'route requires a target' unless defined $target;
        croak 'handler must be a coderef' unless ref($target) eq 'CODE';
        $is_raw = 0;
    }

    my $opts = _option_hash('route', @args);
    if ($kind eq 'route' && !defined $methods) {
        croak 'route requires methods option' unless exists $opts->{methods};
        for my $key (keys %$opts) {
            croak "unknown route option '$key'" unless $key eq 'methods';
        }
        $methods = $opts->{methods};
    }
    else {
        for my $key (keys %$opts) {
            if ($kind ne 'route' && $key eq 'methods') {
                my %kind_name = (websocket => 'WebSocket', sse => 'SSE');
                croak $kind_name{$kind} . ' routes do not accept methods';
            }
            croak "unknown route option '$key'";
        }
    }

    my $descriptions = PAGI::Routing::Middleware->_normalize_descriptors(
        $middleware,
        'middleware',
    );
    my $stored_methods = ref($methods) eq 'ARRAY' ? [@$methods] : $methods;

    push @{$self->{declarations}}, {
        node_kind           => $kind,
        declaration_package => $package,
        path                => $path,
        target              => $target,
        is_raw              => $is_raw,
        methods             => $stored_methods,
        middleware          => $descriptions,
        name                => undef,
        desc                => undef,
        constraints         => undef,
    };

    return $self;
}

sub name {
    my ($self, @args) = @_;
    croak 'name requires exactly one value' unless @args == 1;
    my $record = $self->_last_route_for('name');
    PAGI::Routing::Route::_validate_logical_segment('name', $args[0]);
    $record->{name} = $args[0];
    return $self;
}

sub desc {
    my ($self, @args) = @_;
    croak 'desc requires exactly one value' unless @args == 1;
    my $record = $self->_last_route_for('desc');
    PAGI::Routing::Route::_validate_text('desc', $args[0], 0);
    $record->{desc} = $args[0];
    return $self;
}

sub constraints {
    my ($self, @args) = @_;
    my $record = $self->_last_route_for('constraints');
    my $constraints = _option_hash('constraints', @args);
    PAGI::Routing::Route::_validate_constraints($constraints);
    $record->{constraints} = { %$constraints };
    return $self;
}

sub _last_route_for {
    my ($self, $modifier) = @_;
    my $record = $self->{declarations}[-1];
    croak "$modifier called without a preceding compatible route"
        unless $record
            && ($record->{node_kind} eq 'route'
                || $record->{node_kind} eq 'websocket'
                || $record->{node_kind} eq 'sse');
    return $record;
}

sub _declarations {
    my ($self) = @_;
    return [map { _copy_record($_) } @{$self->{declarations}}];
}

sub _router_options {
    my ($self) = @_;
    return {
        desc               => $self->{desc},
        middleware         => [@{$self->{middleware}}],
        not_found          => $self->{not_found},
        method_not_allowed => $self->{method_not_allowed},
    };
}

sub _materialize_nodes {
    my ($self, $materializer) = @_;
    my @nodes;
    for my $record (@{$self->{declarations}}) {
        push @nodes, PAGI::Routing::Route->_new_from(
            $record->{declaration_package},
            $record->{node_kind},
            $record->{path},
            ($record->{is_raw}
                ? ('raw', $record->{target})
                : ($record->{target})),
            (defined $record->{name} ? (name => $record->{name}) : ()),
            (defined $record->{desc} ? (desc => $record->{desc}) : ()),
            (defined $record->{methods} ? (methods => $record->{methods}) : ()),
            (defined $record->{constraints}
                ? (constraints => $record->{constraints}) : ()),
            middleware => $record->{middleware},
        );
    }
    return \@nodes;
}

sub _copy_record {
    my ($record) = @_;
    my %copy = %$record;
    $copy{methods} = [@{$record->{methods}}]
        if ref($record->{methods}) eq 'ARRAY';
    $copy{middleware} = [@{$record->{middleware}}];
    $copy{constraints} = { %{$record->{constraints}} }
        if defined $record->{constraints};
    return \%copy;
}

sub _option_hash {
    my ($name, @args) = @_;
    croak "$name option list must be key/value pairs" if @args % 2;
    for (my $index = 0; $index < @args; $index += 2) {
        croak "$name option names must be strings"
            unless defined $args[$index] && !ref($args[$index]);
    }
    return { @args };
}

1;

__END__

=head1 NAME

PAGI::App::Router::Builder - Internal ordered declaration storage for App Router

=head1 DESCRIPTION

This private module records mutable App Router declarations only. It keeps one
ordered declaration list, captures the package that made each public-style
declaration, and later materializes immutable routing leaves in that same
order. It does not match requests, compile applications, retain request state,
or emit protocol events.

Middleware is normalized when a declaration is recorded. Normal targets are
Context handlers; a native three-channel application must be supplied through
the explicit C<raw> tag. The public C<PAGI::App::Router> facade, structural
groups and mounts, and snapshot materialization are layered on this core.

=cut
