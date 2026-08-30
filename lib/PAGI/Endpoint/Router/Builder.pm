package PAGI::Endpoint::Router::Builder;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);

sub new {
    my ($class, $endpoint, $builder) = @_;
    croak 'Endpoint route builder requires an Endpoint Router object'
        unless blessed($endpoint) && $endpoint->isa('PAGI::Endpoint::Router');
    croak 'Endpoint route builder requires an App Router builder'
        unless blessed($builder) && $builder->isa('PAGI::App::Router::Builder');
    return bless { endpoint => $endpoint, builder => $builder }, $class;
}

sub get {
    my ($self, @args) = @_;
    my $caller = caller;
    return $self->_add_route_from($caller, 'route', ['GET'], @args);
}

sub post {
    my ($self, @args) = @_;
    my $caller = caller;
    return $self->_add_route_from($caller, 'route', ['POST'], @args);
}

sub put {
    my ($self, @args) = @_;
    my $caller = caller;
    return $self->_add_route_from($caller, 'route', ['PUT'], @args);
}

sub patch {
    my ($self, @args) = @_;
    my $caller = caller;
    return $self->_add_route_from($caller, 'route', ['PATCH'], @args);
}

sub delete {
    my ($self, @args) = @_;
    my $caller = caller;
    return $self->_add_route_from($caller, 'route', ['DELETE'], @args);
}

sub head {
    my ($self, @args) = @_;
    my $caller = caller;
    return $self->_add_route_from($caller, 'route', ['HEAD'], @args);
}

sub options {
    my ($self, @args) = @_;
    my $caller = caller;
    return $self->_add_route_from($caller, 'route', ['OPTIONS'], @args);
}

sub any {
    my ($self, @args) = @_;
    my $caller = caller;
    return $self->_add_route_from($caller, 'route', '*', @args);
}

sub route {
    my ($self, @args) = @_;
    my $caller = caller;
    return $self->_add_route_from($caller, 'route', undef, @args);
}

sub websocket {
    my ($self, @args) = @_;
    my $caller = caller;
    return $self->_add_route_from($caller, 'websocket', undef, @args);
}

sub sse {
    my ($self, @args) = @_;
    my $caller = caller;
    return $self->_add_route_from($caller, 'sse', undef, @args);
}

sub _add_route_from {
    my ($self, $caller, $kind, $methods, $path, @args) = @_;
    croak 'route requires a target' unless @args;

    my $middleware = [];
    $middleware = shift @args if ref($args[0]) eq 'ARRAY';
    croak 'route requires a target' unless @args;

    my $handler = shift @args;

    my $endpoint;
    if (ref($handler) eq 'CODE') {
        $endpoint = $handler;
    }
    elsif (!ref($handler) && defined $handler) {
        my $method = $self->{endpoint}->_required_local_method(
            $handler, 'handler',
        );
        my $receiver = $self->{endpoint};
        $endpoint = sub {
            my ($protocol) = @_;
            return $method->($receiver, $protocol);
        };
    }
    else {
        $endpoint = $handler;
    }

    $self->{builder}->_add_route_from(
        $caller, $kind, $methods, $path, $middleware, $endpoint, @args,
    );
    return $self;
}

sub mount {
    my ($self, $path, @args) = @_;
    my $caller = caller;
    if (@args % 2 == 0) {
        for (my $index = 0; $index < @args; $index += 2) {
            next unless defined $args[$index] && !ref($args[$index])
                && $args[$index] eq 'routes'
                && ref($args[$index + 1]) eq 'CODE';
            my $callback = $args[$index + 1];
            my $endpoint = $self->{endpoint};
            my $facade_class = ref($self);
            $args[$index + 1] = sub {
                my ($child) = @_;
                my $facade = $facade_class->new($endpoint, $child);
                return $callback->($facade);
            };
        }
    }
    $self->{builder}->_mount_from($caller, $path, @args);
    return $self;
}

sub http_default {
    my ($self, @args) = @_;
    $self->{builder}->http_default(@args);
    return $self;
}

sub name {
    my ($self, @args) = @_;
    $self->{builder}->name(@args);
    return $self;
}

sub desc {
    my ($self, @args) = @_;
    $self->{builder}->desc(@args);
    return $self;
}

sub constraints {
    my ($self, @args) = @_;
    $self->{builder}->constraints(@args);
    return $self;
}

1;

__END__

=head1 NAME

PAGI::Endpoint::Router::Builder - Private method-binding App Router facade

=head1 DESCRIPTION

This private facade presents the App Router declaration methods to one
constructed L<PAGI::Endpoint::Router>. Unqualified handler names are validated
and captured as exact method CODE values during materialization. Handler
coderefs pass through unchanged. Bound methods receive the Endpoint followed
by the one direct Request, WebSocket, or SSE object supplied by the shared
compiler. All declarations, middleware normalization,
ordering, immutable snapshots, matching, and protocol adaptation remain owned
by the shared App Router and routing compiler.

=cut
