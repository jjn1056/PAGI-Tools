package PAGI::Compose;

use strict;
use warnings;
use Carp qw(croak);
use Exporter 'import';
use Scalar::Util qw(blessed);
use PAGI::Routing::Router ();

our @EXPORT_OK = qw(compose);
our %EXPORT_TAGS = (ALL => [@EXPORT_OK]);

sub compose {
    return __PACKAGE__->new(@_);
}

sub new {
    my ($class, @args) = @_;
    croak 'compose option list must be key/value pairs' if @args % 2;
    my %opts = @args;

    my %allowed = map { $_ => 1 } qw(routes app middleware lifespan);
    for my $key (keys %opts) {
        croak "unknown compose option '$key'" unless $allowed{$key};
    }

    my $has_routes = exists $opts{routes};
    my $has_app = exists $opts{app};
    croak 'compose requires exactly one of routes or app'
        unless $has_routes != $has_app;

    my $routes;
    if ($has_routes) {
        my $validated = PAGI::Routing::Router->new(routes => $opts{routes});
        $routes = $validated->routes;
    }
    else {
        _validate_app_shape($opts{app});
    }

    my $middleware = exists $opts{middleware} ? $opts{middleware} : [];
    _validate_middleware($middleware);
    my $lifespan = exists $opts{lifespan}
        ? _validate_lifespan($opts{lifespan})
        : undef;

    return bless {
        routes     => $routes,
        app        => $has_app ? $opts{app} : undef,
        middleware => [@$middleware],
        lifespan   => $lifespan,
    }, $class;
}

sub _validate_app_shape {
    my ($app) = @_;
    croak 'compose app must be defined' unless defined $app;
    return if ref($app) eq 'CODE' || blessed($app);
    return if !ref($app) && $app =~ /\A[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*\z/;
    croak 'compose app must be a coderef, object, or class name';
}

sub _validate_middleware {
    my ($middleware) = @_;
    croak 'compose middleware must be an arrayref'
        unless ref($middleware) eq 'ARRAY';
    for my $entry (@$middleware) {
        croak 'compose middleware must contain PAGI::Routing::Middleware descriptors'
            unless blessed($entry)
                && $entry->isa('PAGI::Routing::Middleware');
    }
}

sub _validate_lifespan {
    my ($lifespan) = @_;
    croak 'compose lifespan must be a hashref'
        unless ref($lifespan) eq 'HASH';
    my %allowed = map { $_ => 1 } qw(startup shutdown);
    for my $key (keys %$lifespan) {
        croak "unknown lifespan option '$key'" unless $allowed{$key};
    }
    croak 'compose lifespan requires startup or shutdown'
        unless exists $lifespan->{startup} || exists $lifespan->{shutdown};
    for my $key (qw(startup shutdown)) {
        croak "compose lifespan $key must be a coderef"
            if exists $lifespan->{$key} && ref($lifespan->{$key}) ne 'CODE';
    }
    return { %$lifespan };
}

sub routes {
    my ($self) = @_;
    return defined $self->{routes} ? [@{$self->{routes}}] : undef;
}

sub app { return $_[0]->{app} }

sub middleware { return [@{$_[0]->{middleware}}] }

sub lifespan {
    my ($self) = @_;
    return defined $self->{lifespan} ? {%{$self->{lifespan}}} : undef;
}

sub to_app {
    my ($self) = @_;
    require PAGI::Compose::Compiler;
    return PAGI::Compose::Compiler->compile($self);
}

1;

__END__

=head1 NAME

PAGI::Compose - Immutable public application composition description

=head1 SYNOPSIS

    use PAGI::Compose qw(compose);

    my $description = compose(routes => \@routes);
    my $same_description = PAGI::Compose->new(app => $app);

=head1 DESCRIPTION

Constructors create immutable, inspectable descriptions of either a route tree
or an application component, with optional middleware and lifespan callbacks.
They do not load dynamic components or perform request I/O.

=head1 CONSTRUCTORS

=head2 compose

    compose(%options)

Equivalent to C<< PAGI::Compose->new(%options) >>.

=head2 new

    PAGI::Compose->new(routes => \@nodes, %options)
    PAGI::Compose->new(app => $component, %options)

Exactly one of C<routes> or C<app> is required. C<middleware> is an arrayref
of C<PAGI::Routing::Middleware> descriptors and C<lifespan> is a hashref with
C<startup> and/or C<shutdown> coderefs.

=head1 ACCESSORS

C<routes>, C<middleware>, and C<lifespan> return shallow copies of their
containers. C<app> returns the declared application component by identity.

=head1 METHODS

=head2 to_app

Loads C<PAGI::Compose::Compiler> lazily and delegates compilation to it. This
is the explicit boundary where dynamic component loading and coercion occur.

=cut
