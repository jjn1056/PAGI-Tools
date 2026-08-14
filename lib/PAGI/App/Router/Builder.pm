package PAGI::App::Router::Builder;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use PAGI::Routing::Middleware ();
use PAGI::Routing::Mount ();
use PAGI::Routing::Route ();
use PAGI::Routing::Router ();

sub new {
    my ($class, @args) = @_;
    my $opts = _option_hash('router', @args);

    my %allowed = map { $_ => 1 } qw(desc middleware);
    for my $key (keys %$opts) {
        croak "unknown router option '$key'" unless $allowed{$key};
    }

    PAGI::Routing::Route::_validate_text('desc', $opts->{desc}, 0)
        if exists $opts->{desc};
    my $middleware = PAGI::Routing::Middleware->_normalize_descriptors(
        exists $opts->{middleware} ? $opts->{middleware} : [],
        'middleware',
    );

    return bless {
        declarations => [],
        desc         => $opts->{desc},
        middleware   => $middleware,
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

sub group {
    my ($self, @args) = @_;
    my $package = caller;
    return $self->_group_from($package, @args);
}

sub _group_from {
    my ($self, $package, $path, @args) = @_;

    croak 'group path must be a string' unless defined $path && !ref($path);
    my $middleware = [];
    $middleware = shift @args if @args && ref($args[0]) eq 'ARRAY';
    croak 'group requires a callback'
        unless @args == 1 && ref($args[0]) eq 'CODE';
    my $callback = $args[0];
    my $descriptions = PAGI::Routing::Middleware->_normalize_descriptors(
        $middleware,
        'middleware',
    );
    my $child = ref($self)->new;

    push @{$self->{declarations}}, {
        node_kind           => 'group',
        declaration_package => $package,
        path                => $path,
        child               => $child,
        middleware          => $descriptions,
        name                => undef,
        desc                => undef,
        constraints         => undef,
    };

    $callback->($child);
    return $self;
}

sub mount {
    my ($self, @args) = @_;
    my $package = caller;
    return $self->_mount_from($package, @args);
}

sub _mount_from {
    my ($self, $package, $path, @args) = @_;

    croak 'mount path must be a string' unless defined $path && !ref($path);
    my $middleware = [];
    $middleware = shift @args if @args && ref($args[0]) eq 'ARRAY';

    my ($is_raw, $target, $router);
    if (@args == 1) {
        croak 'mount target must be defined' unless defined $args[0];
        croak 'opaque mount target must be a coderef or object with to_app'
            unless ref($args[0]) eq 'CODE'
                || (blessed($args[0]) && $args[0]->can('to_app'));
        _reject_mutable_frontend_target($args[0], 'opaque mount');
        ($is_raw, $target) = (1, $args[0]);
    }
    elsif (@args == 2 && defined $args[0] && !ref($args[0])
            && $args[0] eq 'router') {
        $router = $args[1];
        _validate_router_target($router);
        $is_raw = 0;
    }
    else {
        croak 'mount requires an opaque target or router => target';
    }

    my $descriptions = PAGI::Routing::Middleware->_normalize_descriptors(
        $middleware,
        'middleware',
    );
    push @{$self->{declarations}}, {
        node_kind           => 'mount',
        declaration_package => $package,
        path                => $path,
        target              => $target,
        router              => $router,
        is_raw              => $is_raw,
        middleware          => $descriptions,
        name                => undef,
        desc                => undef,
        constraints         => undef,
    };
    return $self;
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
        _reject_mutable_frontend_target($target, 'raw route');
        croak 'raw target must be an explicitly compiled coderef'
            unless ref($target) eq 'CODE';
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
    my $record = $self->_last_record_for('name');
    PAGI::Routing::Route::_validate_logical_segment('name', $args[0]);
    $record->{name} = $args[0];
    return $self;
}

sub desc {
    my ($self, @args) = @_;
    croak 'desc requires exactly one value' unless @args == 1;
    my $record = $self->_last_record_for('desc');
    PAGI::Routing::Route::_validate_text('desc', $args[0], 0);
    $record->{desc} = $args[0];
    return $self;
}

sub constraints {
    my ($self, @args) = @_;
    my $record = $self->_last_record_for('constraints');
    my $constraints = _option_hash('constraints', @args);
    PAGI::Routing::Route::_validate_constraints($constraints);
    $record->{constraints} = { %$constraints };
    return $self;
}

sub _last_record_for {
    my ($self, $modifier) = @_;
    my $record = $self->{declarations}[-1];
    croak 'opaque mounts cannot be named'
        if $record && $modifier eq 'name'
            && $record->{node_kind} eq 'mount' && $record->{is_raw};
    croak "$modifier called without a preceding compatible declaration"
        unless $record
            && (($record->{node_kind} eq 'route'
                || $record->{node_kind} eq 'websocket'
                || $record->{node_kind} eq 'sse')
                || ($record->{node_kind} eq 'group')
                || ($record->{node_kind} eq 'mount'
                    && ($modifier ne 'name' || !$record->{is_raw})));
    return $record;
}

sub _declarations {
    my ($self) = @_;
    return [map { _copy_record($_) } @{$self->{declarations}}];
}

sub _router_options {
    my ($self) = @_;
    return {
        desc       => $self->{desc},
        middleware => [@{$self->{middleware}}],
    };
}

sub _materialize_nodes {
    my ($self, $materializer) = @_;
    my @nodes;
    for my $record (@{$self->{declarations}}) {
        if ($record->{node_kind} eq 'group') {
            push @nodes, PAGI::Routing::Mount->_new_from(
                $record->{declaration_package}, $record->{path},
                routes => $record->{child}->_materialize_nodes($materializer),
                _common_mount_options($record),
            );
            next;
        }

        if ($record->{node_kind} eq 'mount') {
            if ($record->{is_raw}) {
                push @nodes, PAGI::Routing::Mount->_new_from(
                    $record->{declaration_package}, $record->{path},
                    $record->{target},
                    _common_mount_options($record),
                );
            }
            else {
                my $child = $materializer->materialize(
                    $record->{router},
                    $record->{path} . ':'
                        . (defined $record->{name} ? $record->{name} : ''),
                );
                push @nodes, PAGI::Routing::Mount->_new_from(
                    $record->{declaration_package}, $record->{path},
                    router => $child,
                    _common_mount_options($record),
                );
            }
            next;
        }

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

sub _materialize_with {
    my ($self, $materializer) = @_;
    my $options = $self->_router_options;
    return PAGI::Routing::Router->new(
        routes     => $self->_materialize_nodes($materializer),
        middleware => $options->{middleware},
        (defined $options->{desc} ? (desc => $options->{desc}) : ()),
    );
}

sub to_router {
    my ($self) = @_;
    require PAGI::App::Router::Materializer;
    my $materializer = PAGI::App::Router::Materializer->new;
    return $materializer->materialize($self, '<root>');
}

sub to_app {
    my ($self) = @_;
    my $router = $self->to_router;
    return $router->to_app;
}

sub _common_mount_options {
    my ($record) = @_;
    return (
        (defined $record->{name} ? (name => $record->{name}) : ()),
        (defined $record->{desc} ? (desc => $record->{desc}) : ()),
        (defined $record->{constraints}
            ? (constraints => $record->{constraints}) : ()),
        middleware => $record->{middleware},
    );
}

sub _validate_router_target {
    my ($target) = @_;
    return if blessed($target)
        && $target->isa('PAGI::Routing::Router');

    my $is_app = blessed($target)
        && ($target->isa('PAGI::App::Router::Builder')
            || $target->isa('PAGI::App::Router'));
    my $is_endpoint = blessed($target)
        && $target->isa('PAGI::Endpoint::Router');
    return if ($is_app || $is_endpoint)
        && $target->can('_materialize_with');

    croak 'router target must be an immutable Router, App Router, or Endpoint Router';
}

sub _reject_mutable_frontend_target {
    my ($target, $position) = @_;
    return unless blessed($target)
        && ($target->isa('PAGI::App::Router::Builder')
            || $target->isa('PAGI::App::Router')
            || $target->isa('PAGI::Endpoint::Router'));

    croak "mutable router frontend cannot be used as a $position target; "
        . 'use router => or an explicitly compiled app coderef';
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
ordered declaration list at each level, captures the package that made each
public-style declaration, and materializes immutable routing leaves and
structural Mounts in that same order. It does not match requests, retain
request state, or emit protocol events.

The Router-level constructor surface is C<desc> and C<middleware>. Routing
fallback policy is ordinary middleware rather than Builder callback storage.

Middleware is normalized when a declaration is recorded. Normal targets are
Context handlers; a native three-channel application must be supplied through
the explicit C<raw> tag. Mutable router frontends are accepted only through a
known C<< router => >> mount, never as opaque or raw targets; callers that need
an opaque application boundary must compile the frontend explicitly first.
Each C<to_router> call uses a fresh root-local Materializer, so later Builder
mutations cannot alter an existing snapshot. C<to_app> compiles one such
retained snapshot as a low-level routing component; HTTP exhaustion remains
unanswered until routing fallback middleware or an enclosing
L<PAGI::Compose> boundary handles it. The public C<PAGI::App::Router> facade is
layered on this core.

=cut
