package PAGI::Routing::URL;

use strict;
use warnings;
use namespace::autoclean;
use Sub::Util ();
use PAGI::Utils::_Exporter ();

my (%EXPORTS, %TAGS, @DEFAULTS);
BEGIN {
    %EXPORTS = (
        url => Sub::Util::set_subname('PAGI::Routing::URL::url',
            sub { return __PACKAGE__->new(@_) }),
        path_for => \&path_for,
        url_for  => \&url_for,
    );
    %TAGS = (all => [sort keys %EXPORTS]);
}
sub import   { PAGI::Utils::_Exporter::export(__PACKAGE__, \%EXPORTS, \%TAGS, \@DEFAULTS, scalar caller, @_) }
sub _exports { \%EXPORTS }

use Carp qw(croak);
use Scalar::Util qw(blessed);
use PAGI::Routing::Resolver ();
use PAGI::Utils::Scope ();

=encoding UTF-8

=head1 NAME

PAGI::Routing::URL - Scope-bound reverse routing facade

=head1 SYNOPSIS

    use PAGI::Routing::URL qw(url path_for url_for);

    my $urls = url($request);
    my $path = $urls->path_for('show', { id => 42 });
    my $absolute = $urls->url_for(
        'show',
        query    => { view => 'full' },
        fragment => 'details',
    );

    my $same_path = path_for($scope, 'show', { id => 42 });
    my $same_url  = url_for($scope, 'show', { id => 42 });

=head1 DESCRIPTION

C<PAGI::Routing::URL> provides handler-bound reverse routing from the current
version-1 C<pagi.routing> frame. It accepts an unblessed scope hashref or an
object with a C<scope> method. The facade stores that exact scope and reads its
current routing frame when each operation runs, so construction does not
freeze an ancestor frame before final route selection.

The facade is cheap and has no identity guarantee. It stores no helper object,
cache record, Resolver record, or other key in the scope. Rendering remains in
L<PAGI::Routing::Resolver>; this class only validates the routing frame and
supplies its request-local namespace, captures, root boundary, and scope.

=head1 EXPORTS

Nothing is exported by default. C<url>, C<path_for>, and C<url_for> are opt-in
named exports and are all available through the C<:all> tag.

=head2 url

    my $urls = url($scope);
    my $urls = url($request);

Constructs and returns a C<PAGI::Routing::URL> facade. It always accepts
exactly one source and never changes return type based on arity.

=cut

=head1 CONSTRUCTOR

=head2 new

    my $urls = PAGI::Routing::URL->new($scope);
    my $urls = PAGI::Routing::URL->new($request);

Stores the exact scope obtained from one unblessed scope hashref or object with
a C<scope> method. Routing metadata is validated when C<path_for> or C<url_for>
runs so the operation observes the latest selected frame.

=cut

sub new {
    my ($class, @arguments) = @_;
    my $scope = PAGI::Utils::Scope::scope_from_source($class, @arguments);
    return bless { scope => $scope }, $class;
}

=head1 METHODS AND DELEGATED FUNCTIONS

=head2 path_for

    my $path = $urls->path_for('show', { id => 42 });
    my $path = path_for($request, 'show', { id => 42 });

Resolves a route relative to the current frame unless its reference begins
with C</>. Relative calls inherit only captures required by the exact target;
explicit parameters override inherited values. The compiled routing boundary's
C<root_path> is encoded and applied exactly once.

Names are logical addresses, not URL paths. Inside a Mount:

    compose(routes => [
        route('/' => \&home, name => 'home'),
        mount('/api', routes => [
            route('/notes/{id}' => \&show_note,  name => 'note'),
            route('/notes'      => \&list_notes, name => 'notes'),
        ], name => 'api'),
        mount('/static', app => $files, name => 'static'),
    ]);

    path_for($request, '/api/note', { id => 1 });   # /api/notes/1, from anywhere
    path_for($request, 'notes');                      # /api/notes, from a handler in api
    path_for($request, '../home');                    # /, from a handler in api
    path_for($request, '/static', { path => 'app.css' });  # /static/app.css, from anywhere

L<PAGI::Tools::Cookbook/"Linking inside a mounted app"> runs this example
and L<PAGI::Tools::Cookbook/"Linking to static files"> its C</static> line;
L</REFERENCES> and L</PLACEMENT AND ROOT PATH> have the full rules.

=cut

sub path_for {
    my ($source, @arguments) = @_;
    my $self = blessed($source) && $source->isa(__PACKAGE__)
        ? $source
        : __PACKAGE__->new($source);
    return $self->_path_for(@arguments);
}

sub _path_for {
    my $self = shift;
    return $self->_reverse_for('path_for', @_);
}

=head2 url_for

    my $absolute = $urls->url_for('show', { id => 42 });
    my $absolute = url_for($request, 'show', { id => 42 });

Uses the same reference and reverse-argument rules as C<path_for>, then
returns an absolute URL. HTTP and SSE targets map the scope scheme to C<http>
or C<https>; WebSocket targets map it to C<ws> or C<wss>. The authority is
that of the request's L<PAGI::Utils::URI>: the client's C<Host> as sent (else the
server address), percent-encoded, and not validated; use TrustedHosts to
accept only the hosts the application serves.

Both operations accept compact C<(\%params, \%query, $fragment)> and named
C<(params =E<gt> ..., query =E<gt> ..., fragment =E<gt> ...)> forms. Query
pairs are sorted and component encoded. Dots navigate only when a complete
logical component is exactly C<.> or C<..>; lookup otherwise remains exact.

=cut

sub url_for {
    my ($source, @arguments) = @_;
    my $self = blessed($source) && $source->isa(__PACKAGE__)
        ? $source
        : __PACKAGE__->new($source);
    return $self->_url_for(@arguments);
}

sub _url_for {
    my $self = shift;
    return $self->_reverse_for('url_for', @_);
}

sub _reverse_for {
    my ($self, $operation, $reference, @reverse_arguments) = @_;
    my $frame = $self->_routing_frame($operation);
    my $scope = $self->{scope};
    my $root_path = exists $frame->{root_path}
        ? $frame->{root_path}
        : $scope->{root_path};
    return $frame->{resolver}->reverse_for_scope(
        $operation,
        $scope,
        $reference,
        $root_path,
        $frame->{logical_namespace},
        $frame->{captures},
        @reverse_arguments,
    );
}

sub _routing_frame {
    my ($self, $operation) = @_;
    my $container = $self->{scope}{'pagi.routing'};
    my $valid = ref($container) eq 'HASH'
        && defined $container->{version}
        && !ref($container->{version})
        && $container->{version} eq '1'
        && ref($container->{frames}) eq 'ARRAY'
        && @{$container->{frames}};

    if ($valid) {
        for my $frame (@{$container->{frames}}) {
            $valid = 0, last unless ref($frame) eq 'HASH'
                && blessed($frame->{resolver})
                && $frame->{resolver}->can('path_for')
                && $frame->{resolver}->can('reverse_for_scope')
                && PAGI::Routing::Resolver::_is_canonical_namespace(
                    $frame->{logical_namespace},
                )
                && ref($frame->{captures}) eq 'HASH'
                && ref($frame->{mounts}) eq 'ARRAY'
                && (!defined $frame->{match} || ref($frame->{match}) eq 'HASH')
                && (!exists $frame->{root_path}
                    || (defined $frame->{root_path} && !ref($frame->{root_path})));
        }
    }

    croak "$operation requires a PAGI::Routing resolver in scope"
        unless $valid;
    return $container->{frames}[-1];
}

1;

=head1 REFERENCES

References use exact filesystem-like normalization:

    /person/blog/show   absolute from this resolver root
    show                relative to the current containing namespace
    blog/show           child of that namespace
    ./show              same namespace
    ../show             parent namespace
    blog/../show        normalized left to right

Empty or repeated segments, trailing slashes, traversal above root, unknown
exact addresses, and results ending at the root or with a terminal C<.> or
C<..> croak. Resolution never searches ancestors, retries an absolute spelling, or
folds overlapping prefixes. References are not URI-decoded. A dot within one
segment, such as C<v1.1>, stays literal.

For a named leaf, the current containing namespace is its absolute address
without the final local name. An unnamed leaf, including a catch-all, uses the
namespace contributed by its enclosing Router mounts. A Router-owned NONE
outcome uses the owning Router placement and captures only prefixes actually
consumed; it does not borrow an arbitrary partial leaf.

=head1 ARGUMENTS

All reverse helpers accept compact and named argument forms:

    $routing->path_for('/person/show', { person_id => 42 });
    path_for($request, 'show', { person_id => 42 }, { tab => 'profile' });
    url_for($request, 'show', {}, {}, 'details');
    url_for($request, 'show',
        query    => { tab => 'profile' },
        fragment => 'details',
    );

Compact order is C<(\%params, \%query, $fragment)>; empty hashrefs are
placeholders when a component is skipped. In the named form C<params>,
C<query>, and C<fragment> are optional and order-independent. A first trailing
hashref selects compact form; a first trailing defined plain scalar selects
named form. The forms cannot be mixed. Params and query must be hashrefs, and
a fragment is a plain scalar or undef. C<undef> omits a fragment and an empty
string emits a terminal C<#>. Query keys are sorted and all query and
fragment components are UTF-8 percent-encoded. Output order is path, query,
then fragment.

=head1 PLACEMENT AND ROOT PATH

Both functions accept a Request, WebSocket, SSE, or raw scope.
Router C<path_for> starts at that Router's local root, inherits no request
captures, and cannot know an external placement. A scope-bound URL helper uses
the active request placement and adds the compiled-router entry C<root_path>
exactly once. A relative reference inherits only captured keys needed by the
target; explicit params override them. Absolute references inherit nothing.
Query and fragment values never inherit.

The same immutable child Router may be mounted at several paths and names. It
stores no parent placement. A scope-bound URL helper follows the active
request-local placement; calling the child Router's own C<path_for> still
returns its local path. Each placement and each C<to_app> call receives a fresh
compiled middleware graph.

Scope C<root_path> is decoded Unicode. Scope-bound reverse routing
percent-encodes it component-wise while preserving slashes, then joins it to
the resolver's already escaped path without double-encoding route or query
values.

=head1 AUTHORITY AND PROXIES

C<url_for> selects HTTP(S) or WS(S) from the route kind and uses
the L<PAGI::Utils::URI> authority of the scope: the Host as sent, else the
server address. A malformed or repeated Host is escaped into the URL, never
validated, and does not fall back. Routing does not parse Forwarded or
X-Forwarded headers. Reverse helpers return strings or croak. They perform no
receive/send calls, emit no protocol events, do not redirect, and do not mutate
a response.

Behind a trusted proxy, use this outer-to-inner order:

    ReverseProxy -> TrustedHosts -> PAGI::Routing

ReverseProxy restores the scheme, client and Host of HTTP, WebSocket and SSE
scopes alike. TrustedHosts is HTTP-only and passes WebSocket/SSE scopes
through, so those arrive with the Host ReverseProxy restored but unchecked
against an allow-list; routing does not supply that check.

=head1 CAPTURES ARE NOT PERMISSION

Inheritance constructs a URL; it does not authorize the target. A captured
tenant, account, or user identifier says nothing about whether the current
principal may access it. Handlers must authorize normally.

=head1 OWNERSHIP

Route URL generation belongs to this facade. Normal handlers pass their direct
Request, WebSocket, or SSE object; raw applications may pass the scope itself.

=head1 SEE ALSO

L<PAGI::Routing>, L<PAGI::Routing::Router>, L<PAGI::Routing::Resolver>,
L<PAGI::Authority>

=cut
