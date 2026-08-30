package PAGI::Routing::Mount;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use PAGI::Routing::Route ();
use PAGI::Routing::Middleware ();
use PAGI::Routing::Pattern ();
use PAGI::Utils ();

sub new {
    my ($class, @args) = @_;
    my $declaration_package = caller;
    return $class->_new_from($declaration_package, @args);
}

sub _new_from {
    my ($class, $declaration_package, $path, @args) = @_;
    croak 'mount path must be a string' unless defined $path && !ref($path);
    croak 'mount option list must be key/value pairs' if @args % 2;

    my %opts = @args;
    my %allowed = map { $_ => 1 }
        qw(app routes name desc constraints middleware);
    for my $key (keys %opts) {
        croak "unknown mount option '$key'" unless $allowed{$key};
    }

    my $has_app = exists $opts{app};
    my $has_routes = exists $opts{routes};
    croak 'mount requires exactly one of app or routes'
        unless $has_app != $has_routes;

    PAGI::Routing::Route::_validate_text('desc', $opts{desc}, 0) if exists $opts{desc};
    PAGI::Routing::Route::_validate_logical_segment('name', $opts{name}) if exists $opts{name};
    PAGI::Routing::Route::_validate_constraints($opts{constraints}) if exists $opts{constraints};
    my $constraints = exists $opts{constraints}
        ? $opts{constraints}
        : {};
    my $middleware = PAGI::Routing::Middleware->_normalize_descriptors(
        exists $opts{middleware} ? $opts{middleware} : [],
        'middleware',
    );

    my $app = $has_app
        ? PAGI::Utils::_validate_app_value($opts{app}, 'mount app')
        : do {
            require PAGI::Routing::Router;
            PAGI::Routing::Router->new(routes => $opts{routes});
        };

    my $pattern = PAGI::Routing::Pattern->new(
        path => $path,
        mode => 'mount',
        constraints => $constraints,
        declaration_package => $declaration_package,
    );

    return bless {
        kind        => 'mount',
        _pattern    => $pattern,
        app         => $app,
        name        => $opts{name},
        desc        => $opts{desc},
        middleware  => $middleware,
    }, $class;
}

sub _validate_routes {
    my ($routes) = @_;
    croak 'routes must contain PAGI::Routing nodes' unless ref($routes) eq 'ARRAY';
    for my $node (@$routes) {
        croak 'PAGI::Routing::Router objects cannot appear in structural routes; '
            . "mount('/prefix', app => \$router)"
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
sub app         { $_[0]->{app} }
sub constraints { $_[0]->{_pattern}->constraints }
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

    my $app_mount = PAGI::Routing::Mount->new('/api', app => $app);
    my $named = PAGI::Routing::Mount->new(
        '/api', app => $router, name => 'api',
    );
    my $inline = PAGI::Routing::Mount->new('/api', routes => \@nodes);

=head1 DESCRIPTION

Routes describe endpoint leaves, Mount describes one prefixed application, and
Router describes an ordered collection of Route and Mount descriptions. A
Mount accepts exactly one of C<app> or C<routes>. C<app> retains its original
base application exactly: a CODE is a native three-channel PAGI application,
and an instantiated C<to_app> object is normalized as one. C<routes> is shorthand for constructing a real child
L<PAGI::Routing::Router> and storing that Router as C<app>. Both named and
unnamed mounts use this same representation:

    mount('/api', app => $api_app, name => 'api')
    mount('/public', routes => [ route('/status' => $handler) ])

The ownership comparison is:

    Route('/x')       exact complete path leaf
    Route('/*path')   explicit real catchall leaf
    Mount('/x')       selected owner of /x and its complete subtree

A terminal mounted Response therefore ignores the rewritten remaining child
path. That can be useful, but a developer who wants only one complete path
normally wants Route. Package-name strings are not application values.
Unlike Route, Mount has no HTTP method filter and contributes no C<Allow>
evidence. Route owns one complete method-aware leaf and keeps its path; Mount
consumes a prefix, rewrites the child scope, and owns the selected subtree.

Its normalized prefix pattern is compiled during construction. Constructor
work validates/builds configuration only and emits no events.

An inline provider such as C<{id:&Int}> is resolved in the package that
directly called C<mount> or C<new>. Re-exporting C<mount> preserves the
consuming package as that caller; wrapping it in another sub makes the wrapper
package the declaration package. A constructor called from a role method
likewise resolves providers in the role package.

Provider-backed and explicit prefix constraints run before mount middleware
and the base application are selected. Named descendants reuse the same
normalized prefix predicates during reverse routing.

=head1 ACCESSORS

C<kind>, C<path>, C<parameters>, C<name>, C<desc>, C<app>, and
C<constraints> return declaration values. C<constraints> returns a fresh
hashref containing the explicitly declared constraint map, or an empty hashref
when none was declared. Inline path constraints remain represented by the path
pattern and are not reconstructed as entries in this explicit map. C<app>
always returns the one base application. C<middleware> returns a fresh
arrayref of normalized
C<PAGI::Routing::Middleware> descriptions; explicit descriptions retain their
identity. C<methods> returns undef for a mount.

=head1 METHODS

=head2 to_app

Synchronously compiles this mount through a fresh complete one-node router on
every call. It emits no events. When the returned app is later invoked and the
prefix matches, dispatch creates a request-local shallow child scope, merges
captures, rewrites C<path>/C<root_path>, and then calls mount middleware and
the child. C<raw_path> remains unchanged. A root mount consumes no prefix and
leaves C<path>, C<root_path>, and C<raw_path> unchanged.

The selected base application remains the routing boundary after its prefix
matches. A child Router renders its own NONE as a custom or stock 404 and its
own PARTIAL as the built-in 405. Those responses unwind through Mount and
parent Router middleware, but the parent does not resume sibling scanning or
union methods after selecting the Mount. An opaque application is equally
authoritative; silence there is an application lifecycle error, not a parent
routing miss.

See L<PAGI::Routing>, L<PAGI::Routing::Router>, L<PAGI::Compose>, and the
L<routing composition upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md#routing-composition-redesign>.

=cut
