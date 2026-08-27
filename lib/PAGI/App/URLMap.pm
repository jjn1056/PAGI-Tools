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
                my $returned = $app->($new_scope, $receive, $send);
                await Future->wrap($returned);
                return;
            }
        }

        # No match - use default or 404
        if ($default) {
            my $returned = $default->($scope, $receive, $send);
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
a coderef or an instantiated component object with a C<to_app> method.
Package-name strings are rejected.
Mounted apps receive a scope with C<path> stripped of the prefix and
C<root_path> extended with it, per the PAGI specification.

Every selected mount target is an opaque application boundary. URLMap
shallow-clones the scope only to rewrite C<path> and C<root_path>; all other
scope values, including selected C<pagi.routing> metadata, are retained. An
explicit C<default> receives the original scope unchanged. URLMap neither
interprets nor removes routing metadata.

Routers render their own HTTP 404 and 405 outcomes, so a mounted or default
Router application is complete without an additional wrapper. URLMap does not
recognize Router classes or offer a routing-aware mount form.

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

L<PAGI::Compose>, L<PAGI::App::Cascade>

=cut
