package PAGI::Routing::Middleware;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed reftype);
use PAGI::Utils ();

sub new {
    my ($class, $factory, @args) = @_;
    my $is_factory = (reftype($factory) // '') eq 'CODE';

    if (!$is_factory && !blessed($factory)) {
        croak 'middleware requires a coderef, blessed object, or nonempty class name'
            if ref($factory) || !defined($factory) || !length($factory);
        croak "invalid middleware class name; use leading '+' for an exact package"
            unless $factory =~ /\A\+?[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*\z/;
    }
    croak 'middleware configuration must be key/value pairs'
        if @args % 2;

    my %config = @args;
    if (!$is_factory && blessed($factory)) {
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

    if ((reftype($target) // '') eq 'CODE') {
        my $wrapped = $target->($inner_app, %{$self->{config}});
        return _compile_wrapped_app($wrapped, 'middleware factory');
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
    return _compile_wrapped_app($wrapped, 'middleware wrap');
}

sub _require_descriptors {
    my ($class, $entries, $error_prefix) = @_;
    $error_prefix //= 'middleware';

    croak "$error_prefix must be an arrayref"
        unless ref($entries) eq 'ARRAY';

    my @descriptions;
    for my $index (0 .. $#$entries) {
        my $entry = $entries->[$index];
        croak "$error_prefix entry $index must be a "
            . 'PAGI::Routing::Middleware description returned by middleware(...)'
            unless blessed($entry) && $entry->isa($class);
        push @descriptions, $entry;
    }
    return \@descriptions;
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
    }

    return $app;
}

sub _resolve_class {
    my ($name) = @_;

    return substr($name, 1) if substr($name, 0, 1) eq '+';
    return $name if $name =~ /\APAGI::Middleware::/;
    return "PAGI::Middleware::$name";
}

sub _compile_wrapped_app {
    my ($value, $source) = @_;

    my $app = eval { PAGI::Utils::to_app($value) };
    if (my $error = $@) {
        chomp $error;
        my $shape = blessed($value) || ref($value) || 'non-reference';
        croak "$source must return a PAGI application value: $shape: $error";
    }
    return $app;
}

1;

__END__

=head1 NAME

PAGI::Routing::Middleware - Normalized immutable declarative middleware description

=head1 SYNOPSIS

    my $logging = PAGI::Routing::Middleware->new(
        'PAGI::Middleware::AccessLog', format => 'combined',
    );

=head1 DESCRIPTION

This class is the immutable description stored by declarative routers, routes,
mounts, and Compose. Core middleware lists accept only an explicit description
made with C<middleware(...)> or C<new>. Core constructors validate and copy
those descriptions without loading a class, constructing an object, calling
C<wrap>, or performing protocol I/O.

C<middleware($target, %config)> captures every middleware target, including a
class name, factory coderef, or configured C<wrap> object. It supports
deliberate descriptor reuse and inspection before attachment. Accessors return
these descriptions, not bare entries.

    Form                              Meaning
    --------------------------------  ---------------------------------
    middleware($class, %config)       deferred class construction
    middleware($factory, %config)     synchronous app-to-app factory
    middleware($object)               configured object with wrap

Class names may be short, nested short, already PAGI-qualified, or exact:

    middleware('RequestId')
    middleware('Auth::Basic')
    middleware('PAGI::Middleware::RequestId')
    middleware('+MyApp::Middleware::Audit')

=head1 METHODS

=head2 new

    PAGI::Routing::Middleware->new($factory)
    PAGI::Routing::Middleware->new($configured_object)
    PAGI::Routing::Middleware->new($class, %config)

Stores the middleware factory and a shallow copy of its configuration.
Configuration is constructor input for class and coderef factory targets.
Configured objects take no additional descriptor configuration. Objects must
provide C<wrap>. This
validates/builds an immutable compile-time descriptor; it does not call the
factory, construct the class, start a request, or emit an event.

=head2 factory

Returns the original factory, object, or class name.

=head2 config

Returns a shallow copy of the configuration hash.

=head1 COMPILATION

Middleware descriptions are resolved synchronously while a routing application
is compiled. Normalization is the first phase and stores only descriptions;
compilation is the second phase. A factory coderef receives the inner
application followed by its stored configuration and must return an application
value immediately. A configured object is reused by identity and receives
C<< ->wrap($inner_app) >>. A class name is loaded, instantiated with the
stored configuration, and then wrapped. Factory and C<wrap> results may be a
native coderef or an instantiated object with C<to_app>; compilation always
returns native code.

Names beginning with C<PAGI::Middleware::> are already fully qualified. Simple
and nested short names receive that prefix, while a leading C<+> selects an
exact fully qualified class. Resolution happens once for each compiled
wrapper, never once per request.

When a descriptor list is folded, the first entry listed is the outermost
wrapper. Compilation itself performs no protocol I/O. Only the app coderef
returned by the factory or C<wrap> runs at request time and returns the
protocol completion; that app owns whether it calls downstream and which
receive/send events it awaits or emits.

=cut
