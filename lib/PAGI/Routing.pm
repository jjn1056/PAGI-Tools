package PAGI::Routing;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(router route websocket sse mount middleware);
our %EXPORT_TAGS = (
    routes     => [qw(router route websocket sse mount)],
    middleware => [qw(middleware)],
    ALL        => [@EXPORT_OK],
);

sub router {
    require PAGI::Routing::Router;
    return PAGI::Routing::Router->new(@_);
}

sub route {
    require PAGI::Routing::Route;
    return PAGI::Routing::Route->new('route', @_);
}

sub websocket {
    require PAGI::Routing::Route;
    return PAGI::Routing::Route->new('websocket', @_);
}

sub sse {
    require PAGI::Routing::Route;
    return PAGI::Routing::Route->new('sse', @_);
}

sub mount {
    require PAGI::Routing::Mount;
    return PAGI::Routing::Mount->new(@_);
}

sub middleware {
    require PAGI::Routing::Middleware;
    return PAGI::Routing::Middleware->new(@_);
}

1;

__END__

=head1 NAME

PAGI::Routing - Declarative routing constructors

=head1 SYNOPSIS

    use PAGI::Routing qw(:ALL);

    my $app = router(
        routes => [
            route('/health' => sub { ... }, methods => 'GET'),
            mount('/api', routes => [ ... ], namespace => 'API'),
        ],
        middleware => [middleware('PAGI::Middleware::AccessLog')],
    );

=head1 DESCRIPTION

This module exports constructors for immutable routing descriptions. They are
compiled later with C<< $router->to_app >>. Nothing is exported by default;
C<:routes> exports C<router>, C<route>, C<websocket>, C<sse>, and C<mount>,
C<:middleware> exports C<middleware>, and uppercase C<:ALL> exports all six.

=head1 CONSTRUCTORS

=head2 router

    router(routes => \@nodes, middleware => \@middleware)

=head2 route, websocket, sse

    route('/path' => sub { ... }, %options)
    route('/path', raw => $app, %options)

The ordinary form takes a context handler coderef. The C<raw> form is the
explicit application boundary and accepts anything supported by
L<PAGI::Utils/to_app>.

=head2 mount

    mount('/prefix' => $app, %options)
    mount('/prefix', routes => \@nodes, %options)

=head2 middleware

    middleware($factory_or_object_or_class, %config)

Creates a middleware description for use in a routing object's C<middleware>
array.

=cut
