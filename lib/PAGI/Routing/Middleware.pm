package PAGI::Routing::Middleware;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);

sub new {
    my ($class, $factory, @args) = @_;

    croak 'middleware requires a coderef, blessed object, or nonempty class name'
        unless ref($factory) eq 'CODE'
            || blessed($factory)
            || (!ref($factory) && defined $factory
                && $factory =~ /\A\^?[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*\z/);
    croak 'middleware configuration must be key/value pairs'
        if @args % 2;

    my %config = @args;
    if (ref($factory) eq 'CODE') {
        croak 'middleware factory takes no config'
            if %config;
    }
    elsif (blessed($factory)) {
        croak 'middleware object must provide a wrap method'
            unless $factory->can('wrap');
        croak 'middleware object takes no config'
            if %config;
    }

    return bless {
        factory => $factory,
        config  => { %config },
    }, $class;
}

sub factory { $_[0]->{factory} }
sub config  { return { %{$_[0]->{config}} } }

sub _wrap {
    my ($self, $inner_app) = @_;
    my $target = $self->{factory};

    croak 'middleware inner app must be a coderef'
        unless ref($inner_app) eq 'CODE';

    if (ref($target) eq 'CODE') {
        my $wrapped = $target->($inner_app);
        _validate_wrapped_app($wrapped, 'middleware factory');
        return $wrapped;
    }

    my $object;
    if (blessed($target)) {
        $object = $target;
    } else {
        my $class = _resolve_class($target);
        my $file = $class;
        $file =~ s{::}{/}g;
        $file .= '.pm';
        require $file;

        $object = $class->new(%{$self->{config}});
        croak "middleware class $class did not construct an object with wrap"
            unless blessed($object) && $object->can('wrap');
    }

    my $wrapped = $object->wrap($inner_app);
    _validate_wrapped_app($wrapped, 'middleware wrap');
    return $wrapped;
}

sub _normalize_descriptors {
    my ($class, $entries, $error_prefix) = @_;
    $error_prefix = 'middleware' unless defined $error_prefix;

    croak "$error_prefix must be an arrayref"
        unless ref($entries) eq 'ARRAY';

    my @normalized;
    for my $entry (@$entries) {
        if (ref($entry) eq 'CODE') {
            push @normalized, PAGI::Routing::Middleware->new($entry);
            next;
        }
        if (blessed($entry)
                && $entry->isa('PAGI::Routing::Middleware')) {
            push @normalized, $entry;
            next;
        }
        croak "$error_prefix must contain PAGI::Routing::Middleware "
            . 'descriptions or coderef factories';
    }

    return \@normalized;
}

sub _wrap_descriptors {
    my ($class, $descriptors, $inner_app) = @_;

    croak 'middleware descriptors must be an array reference'
        unless ref($descriptors) eq 'ARRAY';
    croak 'middleware inner app must be a coderef'
        unless ref($inner_app) eq 'CODE';

    my $app = $inner_app;
    for my $descriptor (reverse @$descriptors) {
        croak 'middleware descriptors must contain PAGI::Routing::Middleware objects'
            unless blessed($descriptor)
                && $descriptor->isa('PAGI::Routing::Middleware');
        $app = $descriptor->_wrap($app);
        _validate_wrapped_app($app, 'middleware wrap');
    }

    return $app;
}

sub _resolve_class {
    my ($name) = @_;

    return substr($name, 1) if substr($name, 0, 1) eq '^';
    return $name if $name =~ /\APAGI::Middleware::/;
    return "PAGI::Middleware::$name";
}

sub _validate_wrapped_app {
    my ($app, $source) = @_;

    return if ref($app) eq 'CODE';
    my $got = blessed($app) || ref($app) || 'non-reference';
    croak "$source must return PAGI app coderef; got $got";
}

1;

__END__

=head1 NAME

PAGI::Routing::Middleware - Immutable declarative middleware description

=head1 SYNOPSIS

    my $logging = PAGI::Routing::Middleware->new(
        'PAGI::Middleware::AccessLog', format => 'combined',
    );

=head1 METHODS

=head2 new

    PAGI::Routing::Middleware->new($factory)
    PAGI::Routing::Middleware->new($configured_object)
    PAGI::Routing::Middleware->new($class, %config)

Stores the middleware factory and a shallow copy of its configuration.
Configuration is constructor input only for class targets. Coderef factories
capture their own options in a closure, and configured objects take no
additional descriptor configuration. Objects must provide C<wrap>. This
validates/builds an immutable compile-time descriptor; it does not call the
factory, construct the class, start a request, or emit an event.

=head2 factory

Returns the original factory, object, or class name.

=head2 config

Returns a shallow copy of the configuration hash.

=head1 COMPILATION

Middleware descriptions are resolved synchronously while a routing application
is compiled. A factory coderef receives the inner application and must return
an application coderef immediately. A configured object is reused by identity
and receives C<< ->wrap($inner_app) >>. A class name is loaded, instantiated
with the stored configuration, and then wrapped.

Names beginning with C<PAGI::Middleware::> are already fully qualified. Simple
and nested short names receive that prefix, while a leading C<^> selects a
caller-owned fully qualified class. Resolution happens once for each compiled
wrapper, never once per request.

When a descriptor list is folded, the first descriptor listed is the outermost
wrapper. Compilation itself performs no protocol I/O. Only the app coderef
returned by the wrapper runs at request time; that app owns whether it calls
downstream and which receive/send events it awaits or emits.

=cut
