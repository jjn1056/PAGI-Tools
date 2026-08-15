package PAGI::App::URLMap;

use strict;
use warnings;
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use PAGI::Pages;
use PAGI::Utils ();

=head1 NAME

PAGI::App::URLMap - Mount apps at URL path prefixes

=head1 SYNOPSIS

    use PAGI::App::URLMap;

    my $map = PAGI::App::URLMap->new;
    $map->mount('/api'    => $api_app);
    $map->mount('/static' => PAGI::App::File->new(root => $dir));
    my $app = $map->to_app;

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        mounts  => [],
        default => defined $args{default} ? PAGI::Utils::to_app($args{default}) : undef,
    }, $class;
}

sub mount {
    my ($self, $path, $app) = @_;

    $path =~ s{/+$}{};  # Remove trailing slashes
    push @{$self->{mounts}}, [$path, PAGI::Utils::to_app($app)];
    # Keep sorted by length (longest first) for proper matching
    @{$self->{mounts}} = sort { length($b->[0]) <=> length($a->[0]) } @{$self->{mounts}};
    return $self;
}

sub map {
    my ($self, $mapping) = @_;

    while (my ($path, $app) = each %$mapping) {
        $self->mount($path, $app);
    }
    return $self;
}

sub to_app {
    my ($self) = @_;

    my @mounts = @{$self->{mounts}};
    my $default = $self->{default};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        my $path = $scope->{path} // '/';

        for my $mount (@mounts) {
            my ($prefix, $app) = @$mount;

            if ($prefix eq '' || $path eq $prefix || $path =~ /^\Q$prefix\E\//) {
                # Match found - adjust path for mounted app
                my $new_path = $path;
                $new_path =~ s/^\Q$prefix\E//;
                $new_path = '/' if $new_path eq '';

                my $new_scope = {
                    %$scope,
                    path      => $new_path,
                    root_path => ($scope->{root_path} // '') . $prefix,
                };
                delete $new_scope->{'pagi.routing.trace'}
                    if (($scope->{type} // 'http') eq 'http');

                my $returned = $app->($new_scope, $receive, $send);
                await Future->wrap($returned);
                return;
            }
        }

        # No match - use default or 404
        if ($default) {
            my $default_scope = $scope;
            if (($scope->{type} // 'http') eq 'http') {
                $default_scope = { %$scope };
                delete $default_scope->{'pagi.routing.trace'};
            }
            my $returned = $default->($default_scope, $receive, $send);
            await Future->wrap($returned);
        } else {
            my $type = $scope->{type} // '<missing>';
            croak "URLMap has no default for scope type '$type'"
                unless $type eq 'http';
            my $response = PAGI::Pages->not_found($scope);
            await Future->wrap($response->respond($send));
        }
    };
}

1;

__END__

=head1 DESCRIPTION

URLMap routes requests to different apps based on URL path prefix.
Longest prefix match wins. The mounted app sees an adjusted path
with the prefix removed.

Mount targets and C<default> accept anything L<PAGI::Utils/to_app> accepts:
a coderef, a component object with a C<to_app> method, or a class name.
Mounted apps receive a scope with C<path> stripped of the prefix and
C<root_path> extended with it, per the PAGI specification.

Every selected HTTP mount target and C<default> is an opaque application
boundary. URLMap shallow-clones the delegated scope and removes the enclosing
C<pagi.routing.trace> value while preserving path rewriting and unrelated
scope values. Routing evidence created by a selected child is therefore local
to that child and is never published into an enclosing Router or Compose
fallback boundary.

A naked child Router that declines remains unanswered at the opaque boundary;
an enclosing L<PAGI::Compose> treats that as incomplete application output.
Wrap the child Router in its own L<PAGI::Compose> when the mounted application
should render its own 404 or 405. For non-HTTP scopes URLMap does not remove or
reinterpret a same-named scope value.

    # Incomplete opaque child: outer Compose sees silent application output.
    $map->mount('/api' => $api_router->to_app);

    # Complete opaque child: the child Compose owns its fallback response.
    $map->mount('/api' => compose(app => $api_router)->to_app);

The same rule applies to C<default>. URLMap does not recognize Router classes
or offer a routing-aware mount form; use L<PAGI::Routing> C<< router => >>
Mounts when trusted child evidence must remain visible to an outer fallback.

When no mount matches and no C<default> is configured, an HTTP request receives
a 404 response negotiated by L<PAGI::Pages> from the original request scope.
WebSocket, SSE, lifespan, and other non-HTTP exhaustion croak with the scope
type instead of emitting incompatible HTTP events. Selected mounts and an
explicit C<default> remain authoritative opaque boundaries as described above;
URLMap has no Pages configuration surface.

=head1 OPTIONS

=over 4

=item * C<default> - App (coderef, component object, or class name) to use
when no prefix matches

=back

=head1 METHODS

=head2 mount($prefix, $app)

Mount an app at the given path prefix.

=head2 map(\%mapping)

Mount multiple apps from a hashref of prefix => app pairs.

=head1 SEE ALSO

L<PAGI::Compose>, L<PAGI::Routing::Trace>, L<PAGI::App::Cascade>

=cut
