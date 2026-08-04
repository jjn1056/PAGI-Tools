package PAGI::Routing::Route;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);

sub new {
    my ($class, $kind, @args) = @_;
    my $path = shift @args;

    croak 'route path must be a string' unless defined $path && !ref($path);

    my ($target, $is_raw);
    if (@args && defined $args[0] && !ref($args[0]) && $args[0] eq 'raw') {
        shift @args;
        $target = shift @args;
        $is_raw = 1;
    }
    else {
        $target = shift @args;
        $is_raw = 0;
    }

    croak 'route option list must be key/value pairs' if @args % 2;
    my %opts = @args;
    croak 'route requires exactly one of handler or raw' if exists $opts{raw};

    my %allowed = map { $_ => 1 } qw(name desc middleware methods);
    $allowed{constraints} = 1 if $kind eq 'route';
    for my $key (keys %opts) {
        croak "unknown route option '$key'" unless $allowed{$key};
    }

    croak 'route requires exactly one of handler or raw' unless defined $target;
    croak 'handler must be a coderef' unless $is_raw || ref($target) eq 'CODE';

    _validate_text('desc', $opts{desc}, 0) if exists $opts{desc};
    _validate_text('name', $opts{name}, 1) if exists $opts{name};
    _validate_constraints($opts{constraints}) if $kind eq 'route' && exists $opts{constraints};
    _validate_middleware($opts{middleware}) if exists $opts{middleware};

    if ($kind ne 'route' && exists $opts{methods}) {
        my %kind_name = (websocket => 'WebSocket', sse => 'SSE');
        croak $kind_name{$kind} . ' routes do not accept methods';
    }

    my $methods = $kind eq 'route'
        ? _normalize_methods(exists $opts{methods} ? $opts{methods} : 'GET')
        : undef;

    return bless {
        kind        => $kind,
        path        => $path,
        target      => $target,
        is_raw      => $is_raw,
        name        => $opts{name},
        desc        => $opts{desc},
        methods     => $methods,
        constraints => exists $opts{constraints} ? { %{$opts{constraints}} } : undef,
        middleware  => exists $opts{middleware} ? [ @{$opts{middleware}} ] : [],
    }, $class;
}

sub _validate_text {
    my ($label, $value, $required) = @_;
    my $message = $required ? "$label must be a nonempty string" : "$label must be a string";
    croak $message unless defined $value && !ref($value) && (!$required || length $value);
}

sub _validate_constraints {
    my ($constraints) = @_;
    croak 'constraints must be a hashref'
        unless ref($constraints) eq 'HASH';
}

sub _validate_middleware {
    my ($middleware) = @_;
    croak 'middleware must be an arrayref'
        unless ref($middleware) eq 'ARRAY';
    for my $entry (@$middleware) {
        croak 'middleware must contain PAGI::Routing::Middleware descriptors'
            unless blessed($entry) && $entry->isa('PAGI::Routing::Middleware');
    }
}

sub _normalize_methods {
    my ($methods) = @_;
    return '*' if defined $methods && !ref($methods) && $methods eq '*';

    my @methods;
    if (defined $methods && !ref($methods)) {
        @methods = ($methods);
    }
    elsif (ref($methods) eq 'ARRAY') {
        @methods = @$methods;
    }
    else {
        croak "methods must be a method string, arrayref, or '*'";
    }

    croak "methods must be a method string, arrayref, or '*'" unless @methods;

    my %seen;
    my @normalized;
    for my $method (@methods) {
        croak "methods must be a method string, arrayref, or '*'"
            unless defined $method && !ref($method)
                && $method ne '*' && $method =~ /\A[!#\$%&'\+\-.\^_`|~0-9A-Za-z]+\z/;
        $method = uc $method;
        next if $seen{$method}++;
        push @normalized, $method;
        if ($method eq 'GET' && !$seen{HEAD}) {
            $seen{HEAD} = 1;
            push @normalized, 'HEAD';
        }
    }
    return \@normalized;
}

sub kind        { $_[0]->{kind} }
sub path        { $_[0]->{path} }
sub name        { $_[0]->{name} }
sub desc        { $_[0]->{desc} }
sub target      { $_[0]->{target} }
sub is_raw      { $_[0]->{is_raw} }
sub methods     { ref($_[0]->{methods}) eq 'ARRAY' ? [ @{$_[0]->{methods}} ] : $_[0]->{methods} }
sub constraints { defined $_[0]->{constraints} ? { %{$_[0]->{constraints}} } : undef }
sub middleware  { [ @{$_[0]->{middleware}} ] }
sub namespace   { undef }
sub routes      { undef }

sub to_app {
    my ($self) = @_;
    require PAGI::Routing::Compiler;
    return PAGI::Routing::Compiler->compile($self);
}

1;

__END__

=head1 NAME

PAGI::Routing::Route - Immutable declarative route description

=head1 SYNOPSIS

    my $route = PAGI::Routing::Route->new(
        route => '/items', sub { ... }, methods => [qw(GET POST)],
    );

=head1 DESCRIPTION

A route represents an HTTP, WebSocket, or SSE leaf. The ordinary target is a
coderef handler; C<raw> targets remain explicit applications for the compiler
to coerce through L<PAGI::Utils/to_app>. Collection and hash accessors return
shallow copies.

=head1 ACCESSORS

C<kind>, C<path>, C<name>, C<desc>, C<target>, C<is_raw>, C<methods>,
C<constraints>, and C<middleware> return the corresponding declaration values.
C<namespace> and C<routes> return undef for a leaf route.

=head1 METHODS

=head2 to_app

Defers compilation to C<PAGI::Routing::Compiler>.

=cut
