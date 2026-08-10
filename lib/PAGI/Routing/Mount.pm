package PAGI::Routing::Mount;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use PAGI::Routing::Route ();
use PAGI::Routing::Middleware ();
use PAGI::Routing::Pattern ();

sub new {
    my ($class, @args) = @_;
    my $declaration_package = caller;
    return $class->_new_from($declaration_package, @args);
}

sub _new_from {
    my ($class, $declaration_package, $path, @args) = @_;
    croak 'mount path must be a string' unless defined $path && !ref($path);

    my ($has_target, $target, $opts) = _parse_arguments(@args);
    my $has_routes = exists $opts->{routes};
    my $has_router = exists $opts->{router};
    croak 'mount requires exactly one of target, routes, or router'
        unless $has_target + $has_routes + $has_router == 1
            && (!$has_target || defined $target);

    my %allowed = map { $_ => 1 } qw(routes router name desc constraints middleware);
    for my $key (keys %$opts) {
        croak "unknown mount option '$key'" unless $allowed{$key};
    }

    croak 'opaque application mounts do not accept name'
        if $has_target && exists $opts->{name};
    if ($has_router) {
        croak 'router mount target must be a PAGI::Routing::Router'
            unless blessed($opts->{router})
                && $opts->{router}->isa('PAGI::Routing::Router');
        croak 'router mount requires a name'
            unless exists $opts->{name};
    }

    PAGI::Routing::Route::_validate_text('desc', $opts->{desc}, 0) if exists $opts->{desc};
    PAGI::Routing::Route::_validate_logical_segment('name', $opts->{name}) if exists $opts->{name};
    PAGI::Routing::Route::_validate_constraints($opts->{constraints}) if exists $opts->{constraints};
    my $middleware = PAGI::Routing::Middleware->_normalize_descriptors(
        exists $opts->{middleware} ? $opts->{middleware} : [],
        'middleware',
    );

    if ($has_routes) {
        _validate_routes($opts->{routes});
    }

    my $has_constraints = exists $opts->{constraints};
    my $pattern = PAGI::Routing::Pattern->new(
        path => $path,
        mode => 'mount',
        constraints => $has_constraints ? $opts->{constraints} : {},
        declaration_package => $declaration_package,
    );

    return bless {
        kind        => 'mount',
        _pattern    => $pattern,
        target      => $has_target ? $target : undef,
        router      => $has_router ? $opts->{router} : undef,
        is_raw      => $has_target ? 1 : 0,
        routes      => $has_routes ? [ @{$opts->{routes}} ] : undef,
        name        => $opts->{name},
        desc        => $opts->{desc},
        _has_constraints => $has_constraints,
        middleware  => $middleware,
    }, $class;
}

sub _parse_arguments {
    my (@args) = @_;
    my ($has_target, $target) = (0, undef);
    if (@args % 2) {
        $has_target = 1;
        $target = shift @args;
    }

    croak 'mount option list must be key/value pairs' if @args % 2;
    for (my $index = 0; $index < @args; $index += 2) {
        croak 'mount option list must be key/value pairs'
            unless defined $args[$index] && !ref($args[$index]);
    }

    my %opts = @args;
    return ($has_target, $target, \%opts);
}

sub _validate_routes {
    my ($routes) = @_;
    croak 'routes must contain PAGI::Routing nodes' unless ref($routes) eq 'ARRAY';
    for my $node (@$routes) {
        croak 'PAGI::Routing::Router objects cannot appear in structural routes; '
            . "mount('/prefix', router => \$router, name => '...')"
            if blessed($node) && $node->isa('PAGI::Routing::Router');
        croak 'routes must contain PAGI::Routing nodes'
            unless blessed($node)
                && ($node->isa('PAGI::Routing::Route')
                    || $node->isa('PAGI::Routing::Mount'));
    }
}

sub kind        { $_[0]->{kind} }
sub path        { $_[0]->{_pattern}->path }
sub parameters  { $_[0]->{_pattern}->parameters }
sub name        { $_[0]->{name} }
sub desc        { $_[0]->{desc} }
sub target      { $_[0]->{target} }
sub router      { $_[0]->{router} }
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

    my $opaque = PAGI::Routing::Mount->new('/api', $app);
    my $inline = PAGI::Routing::Mount->new('/api', routes => \@nodes);
    my $known = PAGI::Routing::Mount->new(
        '/api', router => $router, name => 'api',
    );

=head1 DESCRIPTION

A mount contains exactly one of a positional opaque application target, an
inline C<routes> array of routing nodes, or an explicit C<router> target.
Application targets remain intact until the compiler converts them through
L<PAGI::Utils/to_app>. A positional C<PAGI::Routing::Router> is deliberately
still an opaque application target; use C<< router => $router >> together with
a local name to declare an inspectable Router mount. Inline mounts may omit a
name; opaque application mounts may not supply one; Router mounts require a
nonempty name. Its normalized prefix pattern is compiled during
construction. Constructor work validates/builds configuration only and emits
no events. Collection and hash accessors return shallow copies.

An inline provider such as C<{id:&Int}> is resolved in the package that
directly called C<mount> or C<new>. Re-exporting C<mount> preserves the
consuming package as that caller; wrapping it in another sub makes the wrapper
package the declaration package. A constructor called from a role method
likewise resolves providers in the role package.

Provider-backed and explicit prefix constraints run before mount middleware or
the inline, Router, or opaque target is selected. Named descendants reuse the
same normalized prefix predicates during reverse routing.

=head1 ACCESSORS

C<kind>, C<path>, C<parameters>, C<name>, C<desc>, C<target>, C<router>,
C<is_raw>, C<routes>, and C<constraints> return declaration values. Exactly one
of C<target>, C<router>, and C<routes> is defined. C<middleware> returns
a fresh arrayref of normalized C<PAGI::Routing::Middleware> descriptions;
explicit descriptions retain their identity. C<methods> returns undef for a
mount. C<routes> returns a shallow copy for an inline mount and
undef otherwise. C<is_raw> is true only for an opaque application mount.

=head1 METHODS

=head2 to_app

Synchronously compiles this mount through a fresh complete one-node router on
every call. It emits no events. When the returned app is later invoked and the
prefix matches, dispatch creates a request-local shallow child scope, merges
captures, rewrites C<path>/C<root_path>, and then calls mount middleware and
the child. C<raw_path> remains unchanged. A root mount consumes no prefix and
leaves C<path>, C<root_path>, and C<raw_path> unchanged.

An explicit Router target remains a child dispatch boundary: after the prefix
matches, that Router owns full, partial, and no-match results, including its
generated 404/405 handlers and protocol outcomes. The parent does not resume
scanning or union methods. Cooperative no-match bubbling is deferred.

=cut
