package PAGI::Routing::Mount;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use PAGI::Routing::Route ();
use PAGI::Routing::Pattern ();

sub new {
    my ($class, $path, @args) = @_;
    croak 'mount path must be a string' unless defined $path && !ref($path);

    my $has_target = !(@args && defined $args[0] && !ref($args[0]) && $args[0] eq 'routes');
    my $target;
    if ($has_target) {
        $target = shift @args;
    }

    croak 'mount option list must be key/value pairs' if @args % 2;
    my %opts = @args;
    my $has_routes = exists $opts{routes};
    croak 'mount requires exactly one of target or routes'
        if $has_target == $has_routes || ($has_target && !defined $target);

    my %allowed = map { $_ => 1 } qw(routes namespace desc constraints middleware);
    for my $key (keys %opts) {
        croak "unknown mount option '$key'" unless $allowed{$key};
    }

    PAGI::Routing::Route::_validate_text('desc', $opts{desc}, 0) if exists $opts{desc};
    PAGI::Routing::Route::_validate_text('namespace', $opts{namespace}, 1) if exists $opts{namespace};
    PAGI::Routing::Route::_validate_constraints($opts{constraints}) if exists $opts{constraints};
    PAGI::Routing::Route::_validate_middleware($opts{middleware}) if exists $opts{middleware};

    if ($has_routes) {
        _validate_routes($opts{routes});
    }

    my $has_constraints = exists $opts{constraints};
    my $pattern = PAGI::Routing::Pattern->new(
        path => $path,
        mode => 'mount',
        constraints => $has_constraints ? $opts{constraints} : {},
    );

    return bless {
        kind        => 'mount',
        _pattern    => $pattern,
        target      => $target,
        is_raw      => $has_routes ? 0 : 1,
        routes      => $has_routes ? [ @{$opts{routes}} ] : undef,
        namespace   => $opts{namespace},
        desc        => $opts{desc},
        _has_constraints => $has_constraints,
        middleware  => exists $opts{middleware} ? [ @{$opts{middleware}} ] : [],
    }, $class;
}

sub _validate_routes {
    my ($routes) = @_;
    croak 'routes must contain PAGI::Routing nodes' unless ref($routes) eq 'ARRAY';
    for my $node (@$routes) {
        croak 'routes must contain PAGI::Routing nodes'
            unless blessed($node)
                && ($node->isa('PAGI::Routing::Route')
                    || $node->isa('PAGI::Routing::Mount')
                    || $node->isa('PAGI::Routing::Router'));
    }
}

sub kind        { $_[0]->{kind} }
sub path        { $_[0]->{_pattern}->path }
sub parameters  { $_[0]->{_pattern}->parameters }
sub name        { undef }
sub namespace   { $_[0]->{namespace} }
sub desc        { $_[0]->{desc} }
sub target      { $_[0]->{target} }
sub is_raw      { $_[0]->{is_raw} }
sub routes      { defined $_[0]->{routes} ? [ @{$_[0]->{routes}} ] : undef }
sub constraints { $_[0]->{_has_constraints} ? $_[0]->{_pattern}->constraints : undef }
sub middleware  { [ @{$_[0]->{middleware}} ] }
sub methods     { undef }

sub _pattern    { $_[0]->{_pattern} }

sub to_app {
    my ($self) = @_;
    require PAGI::Routing::Compiler;
    return PAGI::Routing::Compiler->compile($self);
}

1;

__END__

=head1 NAME

PAGI::Routing::Mount - Immutable declarative mount description

=head1 SYNOPSIS

    my $mount = PAGI::Routing::Mount->new('/api', routes => \@nodes);

=head1 DESCRIPTION

A mount contains either an inline array of routing nodes or an application.
Application targets remain intact until the compiler converts them through
L<PAGI::Utils/to_app>. Its normalized prefix pattern is compiled during
construction. Collection and hash accessors return shallow copies.

=head1 ACCESSORS

C<kind>, C<path>, C<parameters>, C<namespace>, C<desc>, C<target>, C<is_raw>,
C<routes>, C<constraints>, and C<middleware> return declaration values. C<name>
and C<methods> return undef for a mount.

=head1 METHODS

=head2 to_app

Compiles this mount through a fresh complete one-node router on every call.

=cut
