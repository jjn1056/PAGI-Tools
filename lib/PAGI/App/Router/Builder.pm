package PAGI::App::Router::Builder;

use strict;
use warnings;
use Carp qw(croak);
use PAGI::Routing::Middleware ();
use PAGI::Routing::Mount ();
use PAGI::Routing::Route ();
use PAGI::Routing::Router ();
use PAGI::Utils ();

sub new {
    my ($class, @args) = @_;
    my $opts = _option_hash('router', @args);

    my %allowed = map { $_ => 1 } qw(desc middleware http_default);
    for my $key (keys %$opts) {
        croak "unknown router option '$key'" unless $allowed{$key};
    }

    PAGI::Routing::Route::_validate_text('desc', $opts->{desc}, 0)
        if exists $opts->{desc};
    my $middleware = PAGI::Routing::Middleware->_normalize_descriptors(
        exists $opts->{middleware} ? $opts->{middleware} : [],
        'middleware',
    );
    my $has_http_default = exists $opts->{http_default};
    my $http_default = $has_http_default
        ? PAGI::Utils::_validate_app_value(
            $opts->{http_default}, 'router http_default',
        )
        : undef;

    return bless {
        declarations    => [],
        desc            => $opts->{desc},
        middleware      => $middleware,
        has_http_default => $has_http_default,
        http_default    => $http_default,
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

sub mount {
    my ($self, @args) = @_;
    my $package = caller;
    return $self->_mount_from($package, @args);
}

sub _mount_from {
    my ($self, $package, $path, @args) = @_;

    croak 'mount path must be a string' unless defined $path && !ref($path);
    my $opts = _option_hash('mount', @args);
    my %allowed = map { $_ => 1 } qw(app routes middleware);
    for my $key (keys %$opts) {
        croak "unknown mount option '$key'" unless $allowed{$key};
    }
    my $has_app = exists $opts->{app};
    my $has_routes = exists $opts->{routes};
    croak 'mount requires exactly one of app or routes'
        unless $has_app != $has_routes;

    my $descriptions = PAGI::Routing::Middleware->_normalize_descriptors(
        exists $opts->{middleware} ? $opts->{middleware} : [],
        'middleware',
    );
    my $record = {
        node_kind           => 'mount',
        declaration_package => $package,
        path                => $path,
        middleware          => $descriptions,
        name                => undef,
        desc                => undef,
        constraints         => undef,
    };

    if ($has_app) {
        $record->{app} = PAGI::Utils::_validate_app_value(
            $opts->{app}, 'mount app',
        );
    }
    elsif (ref($opts->{routes}) eq 'CODE') {
        my $child = ref($self)->new;
        $record->{child} = $child;
        $opts->{routes}->($child);
    }
    elsif (ref($opts->{routes}) eq 'ARRAY') {
        $record->{child} = [@{$opts->{routes}}];
    }
    else {
        croak 'mount routes must be an arrayref or callback';
    }

    push @{$self->{declarations}}, $record;
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

    my $endpoint = shift @args;
    croak 'route requires a target' unless defined $endpoint;
    PAGI::Utils::_validate_app_value($endpoint, 'route endpoint');

    my $opts = _option_hash('route', @args);
    if ($kind eq 'route' && !defined $methods) {
        if (!exists $opts->{methods}) {
            if (ref($endpoint) ne 'CODE' && $endpoint->can('allowed_methods')) {
                $methods = [$endpoint->allowed_methods];
            }
            else {
                croak 'route requires methods option';
            }
        }
        for my $key (keys %$opts) {
            croak "unknown route option '$key'" unless $key eq 'methods';
        }
        $methods = $opts->{methods} if exists $opts->{methods};
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
        endpoint            => $endpoint,
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

sub http_default {
    my ($self, @args) = @_;
    croak 'http_default requires exactly one application' unless @args == 1;
    croak 'http_default may only be configured once'
        if $self->{has_http_default};
    my $app = PAGI::Utils::_validate_app_value(
        $args[0], 'router http_default',
    );
    $self->{http_default} = $app;
    $self->{has_http_default} = 1;
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
    croak "$modifier called without a preceding compatible declaration"
        unless $record
            && (($record->{node_kind} eq 'route'
                || $record->{node_kind} eq 'websocket'
                || $record->{node_kind} eq 'sse')
                || $record->{node_kind} eq 'mount');
    return $record;
}

sub _declarations {
    my ($self) = @_;
    return [map { _copy_record($_) } @{$self->{declarations}}];
}

sub _router_options {
    my ($self) = @_;
    return {
        desc             => $self->{desc},
        middleware       => [@{$self->{middleware}}],
        has_http_default => $self->{has_http_default},
        http_default     => $self->{http_default},
    };
}

sub _materialize_nodes {
    my ($self, $materializer) = @_;
    my @nodes;
    for my $record (@{$self->{declarations}}) {
        if ($record->{node_kind} eq 'mount') {
            if (exists $record->{app}) {
                push @nodes, PAGI::Routing::Mount->_new_from(
                    $record->{declaration_package}, $record->{path},
                    app => $record->{app},
                    _common_mount_options($record),
                );
            }
            elsif (ref($record->{child}) eq 'ARRAY') {
                push @nodes, PAGI::Routing::Mount->_new_from(
                    $record->{declaration_package}, $record->{path},
                    routes => [@{$record->{child}}],
                    _common_mount_options($record),
                );
            }
            else {
                my $child = $materializer->materialize(
                    $record->{child},
                    $record->{path} . ':'
                        . (defined $record->{name} ? $record->{name} : ''),
                );
                push @nodes, PAGI::Routing::Mount->_new_from(
                    $record->{declaration_package}, $record->{path},
                    app => $child,
                    _common_mount_options($record),
                );
            }
            next;
        }

        push @nodes, PAGI::Routing::Route->_new_from(
            $record->{declaration_package},
            $record->{node_kind},
            $record->{path},
            $record->{endpoint},
            (defined $record->{name} ? (name => $record->{name}) : ()),
            (defined $record->{desc} ? (desc => $record->{desc}) : ()),
            ($record->{node_kind} eq 'route'
                ? (methods => $record->{methods}) : ()),
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
        ($options->{has_http_default}
            ? (http_default => $options->{http_default}) : ()),
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

sub _copy_record {
    my ($record) = @_;
    my %copy = %$record;
    $copy{methods} = [@{$record->{methods}}]
        if ref($record->{methods}) eq 'ARRAY';
    $copy{middleware} = [@{$record->{middleware}}];
    $copy{constraints} = { %{$record->{constraints}} }
        if defined $record->{constraints};
    $copy{child} = [@{$record->{child}}]
        if ref($record->{child}) eq 'ARRAY';
    return \%copy;
}

sub _option_hash {
    my ($name, @args) = @_;
    croak "$name option list must be key/value pairs" if @args % 2;
    my %seen;
    for (my $index = 0; $index < @args; $index += 2) {
        croak "$name option names must be strings"
            unless defined $args[$index] && !ref($args[$index]);
        my $key = $args[$index];
        croak "duplicate $name option '$key'" if exists $seen{$key};
        $seen{$key} = 1;
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
public declaration, and materializes immutable Routes and Mounts in that same
order. It does not match requests, retain request state, or emit protocol
events.

The constructor stores C<desc>, normalized C<middleware>, and the optional
native C<http_default>. An explicit boolean distinguishes omission from the
one configured value and enforces the shared constructor/method one-shot
contract.

Mount records contain either C<app> or C<child>. C<child> is a callback-created
Builder or a copied immutable-node arrayref. There is no group record, router
target, or Mount mode flag. Callback children materialize through the same
root-local Materializer; arrays are passed to declarative Mount C<routes> so
that Mount constructs their real child Router.

Middleware and application shapes normalize when declarations are recorded.
Leaf endpoints, Mount C<app>, and C<http_default> positions use the shared
coderef-or-instantiated-C<to_app> contract. A coderef leaf is an ordinary
protocol handler: HTTP receives L<PAGI::Request>, WebSocket receives
L<PAGI::WebSocket>, and SSE receives L<PAGI::SSE>. Use C<as_app> to place a
native three-channel coderef at a leaf. Mutable frontend objects are valid
opaque application values; callers explicitly use C<to_router> when parent
reverse inspection must discover their names.

Each C<to_router> call creates an independent immutable root snapshot.
C<to_app> compiles exactly one retained snapshot. The public
L<PAGI::App::Router> facade layers convenience inspection on this core.

=cut
