package PAGI::Utils;

use strict;
use warnings;
use Exporter ();
use Future::AsyncAwait;
use Carp qw(croak);
use File::Basename qw(basename dirname);
use File::Spec;
use Scalar::Util qw(blessed);
use PAGI::Lifespan;

our @EXPORT_OK = qw(handle_lifespan to_app is_response app_path);
our %EXPORT_TAGS = (all => \@EXPORT_OK);
our %APP_PATH_SOURCE;

sub import {
    my $class = shift;
    my ($package, $source) = caller;

    if (defined $package && !ref($package)
        && defined $source && !ref($source) && length $source) {
        $APP_PATH_SOURCE{join("\0", $package, $source)} =
            File::Spec->canonpath(File::Spec->rel2abs($source));
    }

    local $Exporter::ExportLevel = 1;
    return Exporter::import($class, @_);
}

sub app_path {
    my ($package, $source) = caller;
    return _app_path_from_origin($package, $source, @_);
}

sub _same_path_component {
    my ($left, $right) = @_;
    return 0 unless defined $left && defined $right;
    return lc($left) eq lc($right) if File::Spec->case_tolerant;
    return $left eq $right;
}

sub _home_from_origin {
    my ($package, $source) = @_;

    croak "app_path cannot determine an application home; set PAGI_HOME"
        unless defined $source && !ref($source) && length $source;

    my $absolute = $APP_PATH_SOURCE{join("\0", $package, $source)};
    $absolute = File::Spec->canonpath(File::Spec->rel2abs($source))
        unless defined $absolute;
    my (undef, $directories, $filename) = File::Spec->splitpath($absolute);
    my @source_dirs = File::Spec->splitdir($directories);
    pop @source_dirs while @source_dirs && $source_dirs[-1] eq '';

    my @package_parts = defined($package) && !ref($package)
        ? split(/::/, $package)
        : ();
    my $module_file = @package_parts ? pop(@package_parts) . '.pm' : '';
    my $matches = length($module_file)
        && _same_path_component($filename, $module_file)
        && @source_dirs >= @package_parts;

    if ($matches) {
        for my $offset (1 .. scalar @package_parts) {
            unless (_same_path_component(
                $source_dirs[-$offset], $package_parts[-$offset]
            )) {
                $matches = 0;
                last;
            }
        }
    }

    my $home = dirname($absolute);
    if ($matches) {
        $home = dirname($home) for @package_parts;
        $home = dirname($home)
            if _same_path_component(basename($home), 'lib');
        $home = dirname($home)
            if _same_path_component(basename($home), 'blib');
    }

    return $home;
}

sub _app_path_from_origin {
    my ($package, $source, @components) = @_;

    for my $index (0 .. $#components) {
        my $component = $components[$index];
        my $position = $index + 1;
        croak "app_path component $position must be a defined, nonempty, "
            . "non-reference relative path component"
            unless defined $component && !ref($component) && length $component;
        croak "app_path component $position must be relative, not absolute"
            if File::Spec->file_name_is_absolute($component);
        my ($volume) = File::Spec->splitpath($component);
        croak "app_path component $position must not specify a volume"
            if defined $volume && length $volume;
    }

    my $home = defined($ENV{PAGI_HOME}) && length($ENV{PAGI_HOME})
        ? $ENV{PAGI_HOME}
        : _home_from_origin($package, $source);
    $home = File::Spec->canonpath(File::Spec->rel2abs($home));

    return $home unless @components;
    return File::Spec->canonpath(File::Spec->catfile($home, @components));
}

# True if $x is a PAGI response value: a blessed object that can respond($send).
# The single source of truth for the "did the handler return a response?" check
# (used by the endpoint and router dispatch paths).
sub is_response {
    my ($x) = @_;
    return blessed($x) && $x->can('respond') ? 1 : 0;
}

async sub handle_lifespan {
    my ($scope, $receive, $send, %opts) = @_;

    my $type = $scope->{type} // '';
    croak "handle_lifespan called with scope type '$type' (expected 'lifespan'). "
        . "Check scope type before calling: "
        . "return await handle_lifespan(...) if \$scope->{type} eq 'lifespan'"
        unless $type eq 'lifespan';

    my $manager = PAGI::Lifespan->for_scope($scope);
    $manager->register(%opts) if $opts{startup} || $opts{shutdown};

    return await $manager->handle($scope, $receive, $send);
}

sub to_app {
    my ($thing) = @_;

    croak "to_app() requires an app, component, or class name"
        unless defined $thing;

    return $thing if ref($thing) eq 'CODE';

    if (blessed($thing)) {
        return $thing->to_app if $thing->can('to_app');
        croak ref($thing) . " looks like middleware, not an app"
            . " - pass it to enable(), or wrap an app with ->wrap(\$app)"
            if $thing->can('wrap');
        croak "Cannot coerce " . ref($thing) . " object to a PAGI app (no to_app method)";
    }

    if (!ref($thing)) {
        croak "Cannot coerce '$thing' to a PAGI app"
            unless $thing =~ /\A\w+(?:::\w+)*\z/;
        unless ($thing->can('to_app')) {
            local $@;
            eval "require $thing; 1" or croak "Failed to load '$thing': $@";
        }
        return $thing->to_app if $thing->can('to_app');
        croak "'$thing' looks like middleware, not an app - pass it to enable()"
            if $thing->can('wrap');
        croak "'$thing' does not have a to_app() method";
    }

    croak "Cannot coerce " . ref($thing) . " reference to a PAGI app";
}

1;

__END__

=head1 NAME

PAGI::Utils - Shared utility helpers for PAGI

=head1 SYNOPSIS

    use PAGI::Utils qw(handle_lifespan);

    return await handle_lifespan($scope, $receive, $send,
        startup  => async sub { my ($state) = @_; ... },
        shutdown => async sub { my ($state) = @_; ... },
    ) if $scope->{type} eq 'lifespan';

    use PAGI::Utils qw(app_path);

    my $home       = app_path();
    my $static     = app_path('static');
    my $stylesheet = app_path('static', 'css', 'app.css');

=head1 FUNCTIONS

=head2 app_path

    use PAGI::Utils qw(app_path);

    my $home = app_path();
    my $file = app_path('static', 'css', 'app.css');

Returns an absolute, platform-canonical string rooted at the application home.
C<PAGI_HOME>, when defined and nonempty, has first precedence; relative values
are resolved from the current working directory. Otherwise, a direct call from
a conventional C<lib/Package.pm> source uses the directory above C<lib>, and a
C<blib/lib/Package.pm> source uses the directory above C<blib>. A caller whose
source filename does not exactly match its package suffix falls back to the
source directory. An empty C<PAGI_HOME> is treated as unset.

Pass one logical, relative path component per argument for portable paths.
Undefined, empty, reference-valued, absolute, and separately volumed components
croak. Wrapper functions are caller-sensitive: call C<app_path> directly from
the application module. If a wrapper is required, localize C<PAGI_HOME> around
its call to select the application home explicitly:

    sub project_file {
        local $ENV{PAGI_HOME} = $APPLICATION_HOME;
        return app_path(@_);
    }

There is no public caller-override form; internal path helpers are not part of
the supported application API.

The helper does not check whether a path exists, create it, resolve symlinks, or
provide a sandbox guarantee. Root-level C<use lib> configuration remains a
separate bootstrap concern; C<app_path> derives paths only after the caller has
already been loaded.

=head2 handle_lifespan

    return await handle_lifespan($scope, $receive, $send,
        startup  => async sub { my ($state) = @_; ... },
        shutdown => async sub { my ($state) = @_; ... },
    ) if $scope->{type} eq 'lifespan';

Consumes lifespan events, runs registered startup/shutdown hooks, and sends
the appropriate completion messages. Hooks are taken from
C<< $scope->{'pagi.lifespan.handlers'} >>, and optional C<startup> and
C<shutdown> callbacks can be passed in via C<%opts>.

B<Important:> This function will C<croak> if called with a non-lifespan scope.
Always check C<< $scope->{type} eq 'lifespan' >> before calling, as shown
in the synopsis.

=head2 to_app

    use PAGI::Utils qw(to_app);

    my $app = to_app($thing);

Coerce C<$thing> into a PAGI application (an async coderef). Accepts:

=over 4

=item * a coderef - returned unchanged

=item * an object with a C<to_app> method - compiled by calling it

=item * a class name with a C<to_app> method - auto-required if needed,
then compiled by calling C<< $class->to_app >>

=back

Anything else croaks. A middleware object or class (something with C<wrap>
but no C<to_app>) gets a croak pointing at C<enable()> instead, since
middleware belongs in middleware position, not app position.

All composition points in this distribution (builder mounts, router
targets, cascades, the test client) call this for you, so user code can
pass components and class names directly:

    mount '/static' => PAGI::App::File->new(root => $dir);
    mount '/api'    => 'MyApp::API';

=cut

=head2 is_response

    croak "handler did not return a response" unless is_response($value);

Returns 1 if C<$value> is a PAGI response value -- a blessed object with a
C<respond> method -- and 0 otherwise. This is the single source of truth for the
"did the handler return a response?" check used across the endpoint and router
dispatch paths, so those checks stay consistent (same predicate, same C<croak>
diagnostics) instead of each re-deriving C<< blessed($x) && $x->can('respond') >>.

=cut
