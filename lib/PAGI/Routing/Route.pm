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
    my $opts = _parse_options(
        [qw(path endpoint name desc middleware methods constraints)],
        @args,
    );
    croak 'route requires a path' unless exists $opts->{path};
    croak 'route requires an endpoint' unless exists $opts->{endpoint};

    my $path = delete $opts->{path};
    my $endpoint = delete $opts->{endpoint};
    return $class->_build(
        $declaration_package, 'route', $path, $endpoint, $opts,
    );
}

sub _new_from {
    my ($class, $declaration_package, $kind, @args) = @_;
    my $path = shift @args;
    croak 'route requires an endpoint' unless @args;
    my $endpoint = shift @args;
    my $opts = _parse_options(
        [qw(name desc middleware methods constraints)],
        @args,
    );
    return $class->_build(
        $declaration_package, $kind, $path, $endpoint, $opts,
    );
}

sub _parse_options {
    my ($allowed_names, @args) = @_;
    croak 'route option list must be key/value pairs' if @args % 2;

    my %allowed = map { $_ => 1 } @$allowed_names;
    my %seen;
    for (my $index = 0; $index < @args; $index += 2) {
        my $key = $args[$index];
        croak "unknown route option '$key'"
            unless defined $key && !ref($key) && $allowed{$key};
        croak "duplicate route option '$key'" if $seen{$key}++;
    }

    my %opts = @args;
    return \%opts;
}

sub _build {
    my ($class, $declaration_package, $kind, $path, $endpoint, $opts) = @_;

    croak 'route path must be a string' unless defined $path && !ref($path);
    PAGI::Utils::_validate_app_value(
        $endpoint, 'route endpoint',
    );

    _validate_text('desc', $opts->{desc}, 0) if exists $opts->{desc};
    _validate_logical_segment('name', $opts->{name}) if exists $opts->{name};
    _validate_constraints($opts->{constraints}) if exists $opts->{constraints};
    my $constraints = exists $opts->{constraints}
        ? $opts->{constraints}
        : {};
    my $middleware = PAGI::Routing::Middleware->_normalize_descriptors(
        exists $opts->{middleware} ? $opts->{middleware} : [],
        'middleware',
    );

    if ($kind ne 'route' && exists $opts->{methods}) {
        my %kind_name = (websocket => 'WebSocket', sse => 'SSE');
        croak $kind_name{$kind} . ' routes do not accept methods';
    }

    my $methods;
    if ($kind eq 'route') {
        if (exists $opts->{methods}) {
            $methods = _normalize_methods($opts->{methods}, 'methods');
        }
        elsif (ref($endpoint) ne 'CODE' && $endpoint->can('allowed_methods')) {
            my @capability_methods = $endpoint->allowed_methods;
            $methods = _normalize_methods(
                \@capability_methods,
                'route endpoint allowed_methods',
            );
        }
        else {
            $methods = _normalize_methods('GET');
        }
    }
    my $pattern = PAGI::Routing::Pattern->new(
        path => $path,
        mode => 'route',
        constraints => $constraints,
        declaration_package => $declaration_package,
    );

    return bless {
        kind        => $kind,
        _pattern    => $pattern,
        endpoint    => $endpoint,
        name        => $opts->{name},
        desc        => $opts->{desc},
        methods     => $methods,
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
    my ($methods, $origin) = @_;
    $origin ||= 'methods';

    my $from_capability = $origin eq 'route endpoint allowed_methods';
    my $shape_error = $from_capability
        ? 'route endpoint allowed_methods must return valid HTTP method strings'
        : "methods must be a method string, arrayref, or '*'";

    return '*'
        if !$from_capability
            && defined($methods) && !ref($methods) && $methods eq '*';

    my @methods;
    if (!$from_capability && defined($methods) && !ref($methods)) {
        @methods = ($methods);
    }
    elsif (ref($methods) eq 'ARRAY') {
        @methods = @$methods;
    }
    else {
        croak $shape_error;
    }

    croak 'route endpoint allowed_methods returned no methods'
        if $from_capability && !@methods;
    croak $shape_error unless @methods;

    my %seen;
    my @normalized;
    for my $method (@methods) {
        croak $shape_error
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
sub endpoint    { $_[0]->{endpoint} }
sub methods     { ref($_[0]->{methods}) eq 'ARRAY' ? [ @{$_[0]->{methods}} ] : $_[0]->{methods} }
sub constraints { $_[0]->{_pattern}->constraints }
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
        path     => '/items',
        endpoint => sub { ... },
        methods  => [qw(GET POST)],
    );

=head1 DESCRIPTION

A route represents an HTTP, WebSocket, or SSE leaf. Its C<name>, when supplied,
is one local logical address segment: it is nonempty, contains no slash, and
is not C<.> or C<..>; dots are literal characters. A CODE endpoint is a
coderef handler: HTTP receives one L<PAGI::Request>, WebSocket receives one
L<PAGI::WebSocket>, and SSE receives one L<PAGI::SSE>. An instantiated object
with C<to_app> is a native application endpoint, compiled once through
L<PAGI::Utils/to_app>. Wrap a native coderef with L<PAGI::Utils/as_app>.
Route endpoints never load package names; middleware positions retain their separate explicit
class-loading contract. Its path pattern is compiled during construction, and
constructor validation performs no request I/O. The description never stores
a request match, protocol object, or handler result. Collection and hash
accessors return shallow copies.

Route and Mount have deliberately different path ownership:

    Route('/x')       exact complete path leaf
    Route('/*path')   explicit real catchall leaf
    Mount('/x')       selected owner of /x and its complete subtree

Target shape never changes that rule. A Response or another instantiated
C<to_app> component is still an exact, method-aware Route endpoint with normal
constraints, middleware, naming, FULL/PARTIAL scanning, 405/Allow behavior,
and GET-supplied automatic HEAD. A coderef is a Request handler unless the
C<as_app> wrapper explicitly gives it the native triplet contract. Package-
name strings are not application values.

Explicit HTTP C<methods> wins. Otherwise an application object's
C<allowed_methods> capability is called once in list context at construction;
otherwise the Route defaults to GET plus automatic HEAD. Only scalar
C<< methods => '*' >> is unrestricted. WebSocket and SSE Routes do not accept
C<methods> and never consult C<allowed_methods>. A routed Endpoint::HTTP object
therefore contributes its advertised verbs and OPTIONS to Router selection;
the Router owns unsupported-method 405 and C<Allow> outcomes.

An inline provider such as C<{id:&Int}> is resolved in the package that
directly called C<route>, C<websocket>, C<sse>, or C<new>. Re-exporting a
constructor preserves the consuming package as that caller; wrapping it in
another sub makes the wrapper package the declaration package. A constructor
called from a role method likewise resolves providers in the role package.

=head1 ACCESSORS

C<kind>, C<path>, C<parameters>, C<name>, C<desc>, C<endpoint>, C<methods>,
and C<constraints> return the corresponding declaration values.
C<constraints> returns a fresh hashref containing the explicitly declared
constraint map, or an empty hashref when none was declared. Inline path
constraints remain represented by the path pattern and are not reconstructed
as entries in this explicit map.
C<middleware> returns a fresh arrayref of normalized
C<PAGI::Routing::Middleware> descriptions; explicit descriptions retain their
identity. C<routes> returns undef for a leaf route.
HTTP C<methods> are normalized at construction; GET includes HEAD. Constraint
values are accepted by HTTP, WebSocket, and SSE leaves, returned as declared,
and validate decoded captures only during a request match or reverse render.
Only HTTP routes accept C<methods>. An inline provider and explicit constraint
may target the same parameter; the inline predicate runs first and both must
pass before the endpoint is selected.

=head1 METHODS

=head2 to_app

Synchronously compiles this route through a fresh complete one-node router on
every call. Compilation resolves middleware and component targets but emits no
events. The returned app performs matching and invokes the handler later;
normal HTTP dispatch awaits and invokes the returned application value against
the original triplet,
normal WebSocket/SSE dispatch awaits the direct protocol handler's completion,
and application endpoints retain native event ownership. Every middleware
wrapper remains a native C<($scope, $receive, $send)> application.

A dynamically returned object's C<to_app> runs once per handler invocation.
It receives the unchanged scope and remaining body stream, with no body or
lifespan replay, and remains opaque to the outer Router's reverse and schema
metadata. Expensive static objects belong directly in Route or another native
application position. Synchronous handlers run inline and can block the event
loop.

=cut
