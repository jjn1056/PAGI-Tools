package PAGI::Middleware::Builder;

use strict;
use warnings;
use Future::AsyncAwait;
use Carp 'croak';
use Scalar::Util qw(blessed);
use PAGI::Utils ();

# Note: We use traditional Perl subs because prototypes don't work with signatures.

=encoding UTF-8

=head1 NAME

PAGI::Middleware::Builder - DSL for composing PAGI middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    # Functional DSL
    my $app = builder {
        enable 'ContentLength';
        enable 'CORS', origins => ['*'];
        enable_if { $_[0]->{path} =~ m{^/api/} } 'RateLimit', limit => 100;
        mount '/static' => $static_app;
        $my_app;
    };

    # Object-oriented interface
    my $builder = PAGI::Middleware::Builder->new;
    $builder->enable('ContentLength');
    $builder->enable('CORS', origins => ['*']);
    $builder->mount('/admin', $admin_app);
    my $app = $builder->to_app($my_app);

=head1 DESCRIPTION

PAGI::Middleware::Builder provides a DSL for composing middleware into
a PAGI application. It supports:

=over 4

=item * Enabling middleware with configuration

=item * Conditional middleware application

=item * Path-based routing (mount)

=item * Middleware ordering

=back

=head1 EXPORTS

=cut

use Exporter 'import';
our @EXPORT = qw(builder enable enable_if mount);

# Current builder context for DSL
our $_current_builder;

=head2 builder

    my $app = builder { ... };

Create a composed application using the DSL. The block should
call enable(), enable_if(), mount(), and return the final app.
The final value of the block is the fallback application and is coerced via
L<PAGI::Utils/to_app>. Return a native coderef or an instantiated component
object directly:

    use PAGI::Pages qw(not_found);

    my $app = builder {
        enable 'ContentLength';
        not_found(detail => 'No matching route');
    };

=cut

sub builder (&) {
    my ($block) = @_;
    local $_current_builder = PAGI::Middleware::Builder->new;
    my $app = $block->();
    return $_current_builder->to_app($app);
}

=head2 enable

    enable 'MiddlewareName', %config;
    enable 'Auth::Basic', %config;        # PAGI::Middleware::Auth::Basic
    enable '+My::Custom::Middleware';     # My::Custom::Middleware (no prefix)
    enable(PAGI::Middleware::GZip->new(level => 9));  # pre-configured instance

Enable a middleware. Short names are prefixed with
'PAGI::Middleware::'. A leading '+' selects the exact package name and is
stripped before loading. Already-qualified PAGI::Middleware::* names are
preserved.

When passed an already-configured middleware instance (an object with a
C<wrap> method), it is used directly. Passing config args alongside an
instance is an error — configure the instance at construction time.

The parentheses are required for the instance form: C<enable $obj> without
them is parsed as an indirect method call and dies with a confusing error.

=cut

sub enable {
    my ($name, %config) = @_;
    croak "enable() must be called inside builder {}" unless $_current_builder;
    $_current_builder->add_middleware($name, %config);
}

=head2 enable_if

    enable_if { $condition } 'MiddlewareName', %config;
    enable_if { $condition } (PAGI::Middleware::GZip->new(level => 9));

Conditionally enable middleware. The condition block receives
the scope and returns true/false. A pre-configured middleware instance
may be passed instead of a class name; config args alongside an instance
are an error.

=cut

sub enable_if (&$;@) {
    my ($condition, $name, %config) = @_;
    croak "enable_if() must be called inside builder {}" unless $_current_builder;
    $_current_builder->add_middleware_if($condition, $name, %config);
}

=head2 mount

    mount '/path' => $app;
    mount '/static' => PAGI::App::File->new(root => $dir);
    mount '/api'    => MyApp::API->new;

Mount an application at a path prefix. Requests matching the
prefix are routed to the mounted app with adjusted paths. The app
argument accepts the two native application forms supported by
L<PAGI::Utils/to_app>: a coderef or an instantiated component object with
C<to_app>. Package-name strings are rejected; load and construct mounted
applications explicitly. Middleware class strings remain valid only in
C<enable> and C<enable_if> middleware positions.

=cut

sub mount {
    my ($path, $app) = @_;
    croak "mount() must be called inside builder {}" unless $_current_builder;
    $_current_builder->add_mount($path, $app);
}

=head1 METHODS

=head2 new

    my $builder = PAGI::Middleware::Builder->new;

Create a new builder instance.

=cut

sub new {
    my ($class) = @_;
    return bless {
        middleware => [],
        mounts     => [],
    }, $class;
}

=head2 enable

    $builder->enable('MiddlewareName', %config);

Add middleware to the stack (OO interface).

=cut

sub add_middleware {
    my ($self, $name, %config) = @_;

    if (blessed($name)) {
        croak "enable() with a middleware instance takes no config"
            . " (configure it at construction time)" if %config;
        croak ref($name) . " does not look like middleware (no wrap method)"
            unless $name->can('wrap');
        push @{$self->{middleware}}, {
            instance  => $name,
            condition => undef,
        };
        return $self;
    }

    my $class = $self->_resolve_middleware($name);
    push @{$self->{middleware}}, {
        class     => $class,
        config    => \%config,
        condition => undef,
    };
    return $self;
}

=head2 enable_if

    $builder->enable_if(\&condition, 'MiddlewareName', %config);

Add conditional middleware to the stack (OO interface).

=cut

sub add_middleware_if {
    my ($self, $condition, $name, %config) = @_;

    if (blessed($name)) {
        croak "enable_if() with a middleware instance takes no config"
            . " (configure it at construction time)" if %config;
        croak ref($name) . " does not look like middleware (no wrap method)"
            unless $name->can('wrap');
        push @{$self->{middleware}}, {
            instance  => $name,
            condition => $condition,
        };
        return $self;
    }

    my $class = $self->_resolve_middleware($name);
    push @{$self->{middleware}}, {
        class     => $class,
        config    => \%config,
        condition => $condition,
    };
    return $self;
}

=head2 mount

    $builder->mount('/path', $app);

Add a path-based mount point (OO interface).

The target must be a native coderef or an instantiated C<to_app> object.
Package-name strings are rejected synchronously.

=cut

sub add_mount {
    my ($self, $path, $app) = @_;
    # Normalize path (remove trailing slash, ensure leading slash)
    $path =~ s{/$}{};
    $path = "/$path" unless $path =~ m{^/};

    push @{$self->{mounts}}, {
        path => $path,
        app  => PAGI::Utils::to_app($app),
    };
    return $self;
}

=head2 to_app

    my $app = $builder->to_app($inner_app);

Build the composed application. C<$inner_app> is the fallback when no Builder
mount matches. It accepts a native coderef or instantiated component object
with C<to_app>; package-name strings are rejected synchronously. This means
C<builder { ...; $router }> and
C<builder { ...; not_found(detail =E<gt> 'No matching route') }> work without
an explicit C<< ->to_app >> call. Pages factories return application-valued
objects and are native at this application boundary. Class strings remain available to C<enable> and
C<enable_if> because those are middleware-loading positions, not application
positions.

=cut

sub to_app {
    my ($self, $app) = @_;
    $app = PAGI::Utils::to_app($app);

    # Apply mounts first (innermost)
    if (@{$self->{mounts}}) {
        $app = $self->_build_mount_app($app);
    }

    # Apply middleware in reverse order (outermost first in execution)
    for my $mw (reverse @{$self->{middleware}}) {
        $app = $self->_wrap_middleware($mw, $app);
    }

    return $app;
}

# Private: resolve middleware class name
sub _resolve_middleware {
    my ($self, $name) = @_;

    croak 'enable() middleware name must be a nonempty scalar'
        if ref($name) || !defined($name) || !length($name);
    croak "invalid middleware class name; use leading '+' for an exact package"
        unless $name =~ /\A\+?[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*\z/;

    # Prefix short names, preserve PAGI::Middleware::* names, and strip one
    # leading + for exact package names.
    # Examples:
    #   'GZIP'           -> 'PAGI::Middleware::GZIP'
    #   'Auth::Basic'    -> 'PAGI::Middleware::Auth::Basic'
    #   '+My::Custom'    -> 'My::Custom' (prefix removed)
    #   'PAGI::Middleware::GZIP' -> 'PAGI::Middleware::GZIP'
    my $class = $name;
    if (substr($class, 0, 1) eq '+') {
        substr($class, 0, 1, '');
    }
    elsif ($class !~ /\APAGI::Middleware::/) {
        $class = "PAGI::Middleware::$class";
    }

    # Load the module
    my $file = $class;
    $file =~ s{::}{/}g;
    $file .= '.pm';

    eval { require $file };
    if ($@) {
        # If loading fails, the error will surface when instantiating
        # This allows for forward declarations
        warn "Warning: Could not load $class: $@" if $ENV{PAGI_DEBUG};
    }

    return $class;
}

# Private: wrap a middleware around an app
sub _wrap_middleware {
    my ($self, $mw, $app) = @_;
    my $condition = $mw->{condition};

    # Pre-configured instance path
    if (my $instance = $mw->{instance}) {
        my $wrapped = $instance->wrap($app);
        return $wrapped unless $condition;
        return async sub {
            my ($scope, $receive, $send) = @_;
            if ($condition->($scope)) {
                await $wrapped->($scope, $receive, $send);
            } else {
                await $app->($scope, $receive, $send);
            }
        };
    }

    # Class name + config path
    my $class  = $mw->{class};
    my $config = $mw->{config};

    if ($condition) {
        # Conditional middleware
        return async sub {
            my ($scope, $receive, $send) = @_;
            if ($condition->($scope)) {
                my $instance = $class->new(%$config);
                my $wrapped  = $instance->wrap($app);
                await $wrapped->($scope, $receive, $send);
            } else {
                await $app->($scope, $receive, $send);
            }
        };
    } else {
        # Unconditional middleware
        my $instance = $class->new(%$config);
        return $instance->wrap($app);
    }
}

# Private: build mount routing app
sub _build_mount_app {
    my ($self, $fallback_app) = @_;
    my @mounts = sort { length($b->{path}) <=> length($a->{path}) } @{$self->{mounts}};

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $path = $scope->{path};

        for my $mount (@mounts) {
            my $prefix = $mount->{path};

            # Check if path matches mount point
            if ($path eq $prefix || $path =~ m{^\Q$prefix\E/}) {
                # Adjust path and root_path for mounted app
                my $new_path = $path;
                $new_path =~ s{^\Q$prefix\E}{};
                $new_path = '/' if $new_path eq '';

                my $new_root = ($scope->{root_path} // '') . $prefix;

                my $mounted_scope = {
                    %$scope,
                    path      => $new_path,
                    root_path => $new_root,
                };

                await $mount->{app}->($mounted_scope, $receive, $send);
                return;
            }
        }

        # No mount matched, use fallback
        await $fallback_app->($scope, $receive, $send);
    };
}

1;

__END__

=head1 MIDDLEWARE ORDERING

Middleware is applied in the order specified, with the first middleware
being the outermost wrapper. This means:

    builder {
        enable 'A';
        enable 'B';
        enable 'C';
        $app;
    };

Results in: A wraps B wraps C wraps $app

Request flow: A -> B -> C -> app -> C -> B -> A

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
