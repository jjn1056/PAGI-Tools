package PAGI::App::Router;

use strict;
use warnings;
use experimental 'signatures';
use Future::AsyncAwait;

=head1 NAME

PAGI::App::Router - URL routing with path parameters

=head1 SYNOPSIS

    use PAGI::App::Router;

    my $router = PAGI::App::Router->new;
    $router->get('/users/:id' => $get_user);
    $router->post('/users' => $create_user);
    $router->delete('/users/:id' => $delete_user);
    my $app = $router->to_app;

=cut

sub new ($class, %args) {
    return bless {
        routes => [],
        not_found => $args{not_found},
    }, $class;
}

sub get    ($self, $path, $app) { $self->route('GET', $path, $app) }
sub post   ($self, $path, $app) { $self->route('POST', $path, $app) }
sub put    ($self, $path, $app) { $self->route('PUT', $path, $app) }
sub patch  ($self, $path, $app) { $self->route('PATCH', $path, $app) }
sub delete ($self, $path, $app) { $self->route('DELETE', $path, $app) }
sub head   ($self, $path, $app) { $self->route('HEAD', $path, $app) }
sub options($self, $path, $app) { $self->route('OPTIONS', $path, $app) }

sub route ($self, $method, $path, $app) {
    my ($regex, @names) = $self->_compile_path($path);
    push @{$self->{routes}}, {
        method => uc($method),
        path   => $path,
        regex  => $regex,
        names  => \@names,
        app    => $app,
    };
    return $self;
}

sub _compile_path ($self, $path) {
    my @names;
    my $regex = $path;

    # Handle wildcard/splat
    if ($regex =~ s{\*(\w+)}{(.+)}g) {
        push @names, $1;
    }

    # Handle named parameters
    while ($regex =~ s{:(\w+)}{([^/]+)}) {
        push @names, $1;
    }

    return (qr{^$regex$}, @names);
}

sub to_app ($self) {
    my @routes = @{$self->{routes}};
    my $not_found = $self->{not_found};

    return async sub ($scope, $receive, $send) {
        my $method = uc($scope->{method} // '');
        my $path = $scope->{path} // '/';

        # HEAD should match GET routes
        my $match_method = $method eq 'HEAD' ? 'GET' : $method;

        my @method_matches;

        for my $route (@routes) {
            if ($path =~ $route->{regex}) {
                my @captures = ($path =~ $route->{regex});

                # Check method
                if ($route->{method} eq $match_method || $route->{method} eq $method) {
                    # Build params
                    my %params;
                    for my $i (0 .. $#{$route->{names}}) {
                        $params{$route->{names}[$i]} = $captures[$i];
                    }

                    my $new_scope = {
                        %$scope,
                        'pagi.router' => {
                            params => \%params,
                            route  => $route->{path},
                        },
                    };

                    await $route->{app}->($new_scope, $receive, $send);
                    return;
                }

                push @method_matches, $route->{method};
            }
        }

        # Path matched but method didn't - 405
        if (@method_matches) {
            my $allowed = join ', ', sort keys %{{ map { $_ => 1 } @method_matches }};
            await $send->({
                type => 'http.response.start',
                status => 405,
                headers => [
                    ['content-type', 'text/plain'],
                    ['allow', $allowed],
                ],
            });
            await $send->({ type => 'http.response.body', body => 'Method Not Allowed', more => 0 });
            return;
        }

        # No match - 404
        if ($not_found) {
            await $not_found->($scope, $receive, $send);
        } else {
            await $send->({
                type => 'http.response.start',
                status => 404,
                headers => [['content-type', 'text/plain']],
            });
            await $send->({ type => 'http.response.body', body => 'Not Found', more => 0 });
        }
    };
}

1;

__END__

=head1 PATH PATTERNS

=over 4

=item * C</users/:id> - Named parameter, captured as C<params-E<gt>{id}>

=item * C</files/*path> - Wildcard, captures rest of path as C<params-E<gt>{path}>

=back

=head1 SCOPE ADDITIONS

The matched route adds C<pagi.router> to scope:

    $scope->{'pagi.router'}{params}  # Captured parameters
    $scope->{'pagi.router'}{route}   # Matched route pattern

=cut
