package PAGI::Routing::Route;

use strict;
use warnings;
use Carp qw(croak);
use PAGI::Utils ();
use PAGI::Routing::Middleware ();
use PAGI::Routing::Pattern ();

sub new {
    my ($class, @args) = @_;
    my $declaration_package = caller;
    return $class->_new_from($declaration_package, @args);
}

sub _new_from {
    my ($class, $declaration_package, $kind, @args) = @_;
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

    my %allowed = map { $_ => 1 } qw(name desc middleware methods constraints);
    for my $key (keys %opts) {
        croak "unknown route option '$key'" unless $allowed{$key};
    }

    croak 'route requires exactly one of handler or raw'
        unless $is_raw || defined $target;
    PAGI::Utils::_validate_app_value(
        $target, $is_raw ? 'raw application' : 'route target',
    );

    _validate_text('desc', $opts{desc}, 0) if exists $opts{desc};
    _validate_logical_segment('name', $opts{name}) if exists $opts{name};
    _validate_constraints($opts{constraints}) if exists $opts{constraints};
    my $middleware = PAGI::Routing::Middleware->_normalize_descriptors(
        exists $opts{middleware} ? $opts{middleware} : [],
        'middleware',
    );

    if ($kind ne 'route' && exists $opts{methods}) {
        my %kind_name = (websocket => 'WebSocket', sse => 'SSE');
        croak $kind_name{$kind} . ' routes do not accept methods';
    }

    my $methods = $kind eq 'route'
        ? _normalize_methods(exists $opts{methods} ? $opts{methods} : 'GET')
        : undef;
    my $has_constraints = exists $opts{constraints};
    my $pattern = PAGI::Routing::Pattern->new(
        path => $path,
        mode => 'route',
        constraints => $has_constraints ? $opts{constraints} : {},
        declaration_package => $declaration_package,
    );

    return bless {
        kind        => $kind,
        _pattern    => $pattern,
        target      => $target,
        is_raw      => $is_raw,
        name        => $opts{name},
        desc        => $opts{desc},
        methods     => $methods,
        _has_constraints => $has_constraints,
        middleware  => $middleware,
    }, $class;
}

sub _validate_text {
    my ($label, $value, $required) = @_;
    my $message = $required ? "$label must be a nonempty string" : "$label must be a string";
    croak $message unless defined $value && !ref($value) && (!$required || length $value);
}

sub _validate_logical_segment {
    my ($label, $value) = @_;
    croak "$label must be one logical address segment"
        unless defined $value && !ref($value) && length $value
            && index($value, '/') < 0 && $value ne '.' && $value ne '..';
}

sub _validate_constraints {
    my ($constraints) = @_;
    croak 'constraints must be a hashref'
        unless ref($constraints) eq 'HASH';
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
sub path        { $_[0]->{_pattern}->path }
sub parameters  { $_[0]->{_pattern}->parameters }
sub name        { $_[0]->{name} }
sub desc        { $_[0]->{desc} }
sub target      { $_[0]->{target} }
sub is_raw      { $_[0]->{is_raw} }
sub methods     { ref($_[0]->{methods}) eq 'ARRAY' ? [ @{$_[0]->{methods}} ] : $_[0]->{methods} }
sub constraints { $_[0]->{_has_constraints} ? $_[0]->{_pattern}->constraints : undef }
sub middleware  { [ @{$_[0]->{middleware}} ] }
sub routes      { undef }
sub _pattern    { $_[0]->{_pattern} }

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

A route represents an HTTP, WebSocket, or SSE leaf. Its C<name>, when supplied,
is one local logical address segment: it is nonempty, contains no slash, and
is not C<.> or C<..>; dots are literal characters. The ordinary target is a
coderef handler: HTTP receives one L<PAGI::Request>, WebSocket receives one
L<PAGI::WebSocket>, and SSE receives one L<PAGI::SSE>. An instantiated object
with C<to_app> is a component target, compiled once through
L<PAGI::Utils/to_app>. C<raw> remains the explicit marker for a native coderef
app. Route targets never load package names; middleware positions retain their separate explicit
class-loading contract. Its path pattern is compiled during construction, and
constructor validation performs no request I/O. The description never stores
a request match, protocol object, or handler result. Collection and hash
accessors return shallow copies.

An inline provider such as C<{id:&Int}> is resolved in the package that
directly called C<route>, C<websocket>, C<sse>, or C<new>. Re-exporting a
constructor preserves the consuming package as that caller; wrapping it in
another sub makes the wrapper package the declaration package. A constructor
called from a role method likewise resolves providers in the role package.

=head1 ACCESSORS

C<kind>, C<path>, C<parameters>, C<name>, C<desc>, C<target>, C<is_raw>,
C<methods>, and C<constraints> return the corresponding declaration values.
C<middleware> returns a fresh arrayref of normalized
C<PAGI::Routing::Middleware> descriptions; explicit descriptions retain their
identity. C<routes> returns undef for a leaf route.
HTTP C<methods> are normalized at construction; GET includes HEAD. Constraint
values are accepted by HTTP, WebSocket, and SSE leaves, returned as declared,
and validate decoded captures only during a request match or reverse render.
Only HTTP routes accept C<methods>. An inline provider and explicit constraint
may target the same parameter; the inline predicate runs first and both must
pass before the normal or raw target is selected.

=head1 METHODS

=head2 to_app

Synchronously compiles this route through a fresh complete one-node router on
every call. Compilation resolves middleware and component targets but emits no
events. The returned app performs matching and invokes the handler later;
normal HTTP dispatch awaits and emits the returned Response exactly once through
C<< respond($scope, $receive, $send) >>,
normal WebSocket/SSE dispatch awaits the direct protocol handler's completion,
and raw dispatch leaves event ownership with the target. Every middleware
wrapper remains a native C<($scope, $receive, $send)> application.

=cut
