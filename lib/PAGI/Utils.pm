package PAGI::Utils;

use strict;
use warnings;
use Exporter ();
use Future;
use Future::AsyncAwait;
use Carp qw(croak);
use File::Basename qw(basename dirname);
use File::Spec;
use Scalar::Util qw(blessed);
use PAGI::Lifespan;
use PAGI::Utils::_App;

my @PAGI_ENVIRONMENTS = qw(development test staging production);
my %VALID_PAGI_ENV = map { $_ => 1 } @PAGI_ENVIRONMENTS;
my @ENV_EXPORTS = qw(
    pagi_env is_development is_test is_staging is_production
);
my @PATH_EXPORTS = qw(
    app_path path_from_root replace_path_prefix
);

our @EXPORT_OK = (
    qw(handle_lifespan to_app as_app invoke_app is_response),
    @ENV_EXPORTS,
    @PATH_EXPORTS,
);
our %EXPORT_TAGS = (
    all => \@EXPORT_OK,
    env => \@ENV_EXPORTS,
    path => \@PATH_EXPORTS,
);
our %APP_PATH_SOURCE;

sub _remember_app_path_origin {
    my ($package, $source) = @_;
    return unless defined $package && !ref($package);
    return unless defined $source && !ref($source) && length($source);

    $APP_PATH_SOURCE{join("\0", $package, $source)} =
        File::Spec->canonpath(File::Spec->rel2abs($source));
    return;
}

sub import {
    my $class = shift;
    my ($package, $source) = caller;
    _remember_app_path_origin($package, $source);

    local $Exporter::ExportLevel = 1;
    return Exporter::import($class, @_);
}

sub pagi_env {
    croak 'pagi_env() does not accept arguments' if @_;

    my $environment = $ENV{PAGI_ENV};
    return 'production' unless defined $environment && length $environment;
    croak "Invalid PAGI_ENV '$environment'; expected one of: "
        . join(', ', @PAGI_ENVIRONMENTS)
        unless $VALID_PAGI_ENV{$environment};
    return $environment;
}

sub _environment_predicate {
    my ($function, $expected, @arguments) = @_;
    croak "$function() does not accept arguments" if @arguments;
    return pagi_env() eq $expected ? 1 : 0;
}

sub is_development {
    return _environment_predicate('is_development', 'development', @_);
}

sub is_test {
    return _environment_predicate('is_test', 'test', @_);
}

sub is_staging {
    return _environment_predicate('is_staging', 'staging', @_);
}

sub is_production {
    return _environment_predicate('is_production', 'production', @_);
}

sub app_path {
    my ($package, $source) = caller;
    return _app_path_from_origin($package, $source, @_);
}

sub _require_path_string {
    my ($name, $value, $allow_empty) = @_;
    my $description = $allow_empty
        ? 'a defined, non-reference string'
        : 'a defined, nonempty, non-reference string';
    croak "$name must be $description"
        unless defined $value && !ref($value) && ($allow_empty || length $value);
    return;
}

sub _validated_request_parts {
    my ($path, $spec_class) = @_;
    $spec_class ||= 'File::Spec';
    my @components = split m{[\\/]}, $path, -1;
    my $directory_intent = $path =~ m{[\\/]\z}
        || @components && $components[-1] eq '.';
    my @parts;

    for my $component (@components) {
        return unless index($component, "\0") < 0;
        return if $component =~ /\A\.{2,}\z/;
        next if $component eq '' || $component eq '.';

        my ($volume) = $spec_class->splitpath($component);
        return if defined $volume && length $volume;
        return if $spec_class->file_name_is_absolute($component);
        push @parts, $component;
    }

    return (\@parts, $directory_intent);
}

sub _path_from_root_with_spec {
    my ($spec_class, $root, $request_path) = @_;

    my ($parts, $directory_intent)
        = _validated_request_parts($request_path, $spec_class);
    return undef unless defined $parts;

    my $absolute_root = $spec_class->canonpath(
        $spec_class->rel2abs($root),
    );
    my $candidate = @$parts
        ? $spec_class->catfile($absolute_root, @$parts)
        : $absolute_root;

    return $candidate unless $directory_intent && @$parts;

    my ($volume, $directories, $filename)
        = $spec_class->splitpath($candidate);
    my $intent_directory = $spec_class->catdir($directories, $filename);
    return $spec_class->catpath(
        $volume, $intent_directory, $spec_class->curdir,
    );
}

sub path_from_root {
    croak 'path_from_root requires a root and request path' unless @_ == 2;
    my ($root, $request_path) = @_;
    _require_path_string('path_from_root root', $root, 0);
    _require_path_string('path_from_root request path', $request_path, 1);

    return _path_from_root_with_spec('File::Spec', $root, $request_path);
}

sub _path_components_with_spec {
    my ($spec_class, $path) = @_;
    my (undef, $directories) = $spec_class->splitpath($path, 1);
    return grep {
        length($_) && $_ ne $spec_class->curdir
    } $spec_class->splitdir($directories);
}

sub _replace_path_prefix_with_spec {
    my ($spec_class, $path, $from, $to) = @_;

    my $absolute_path = $spec_class->canonpath(
        $spec_class->rel2abs($path),
    );
    my $absolute_from = $spec_class->canonpath(
        $spec_class->rel2abs($from),
    );
    my ($path_volume) = $spec_class->splitpath($absolute_path);
    my ($from_volume) = $spec_class->splitpath($absolute_from);
    return undef unless _same_path_component(
        $path_volume, $from_volume, $spec_class,
    );

    my @path_parts = _path_components_with_spec($spec_class, $absolute_path);
    my @from_parts = _path_components_with_spec($spec_class, $absolute_from);
    return undef if @path_parts < @from_parts;
    for my $index (0 .. $#from_parts) {
        return undef unless _same_path_component(
            $path_parts[$index], $from_parts[$index], $spec_class,
        );
    }
    my @suffix = @path_parts[@from_parts .. $#path_parts];
    return undef if grep { $_ eq $spec_class->updir } @suffix;

    my $slash_to = $to;
    $slash_to =~ tr{\\}{/};
    $slash_to =~ s{/+}{/}g;
    $slash_to =~ s{/+\z}{} unless $slash_to =~ m{\A/+\z};
    $slash_to = '/' if $slash_to =~ m{\A/+\z};

    return $slash_to unless @suffix;
    return '/' . join('/', @suffix) if $slash_to eq '/';
    return $slash_to . '/' . join('/', @suffix);
}

sub replace_path_prefix {
    croak 'replace_path_prefix requires path, source prefix, and replacement'
        unless @_ == 3;
    my ($path, $from, $to) = @_;
    _require_path_string('replace_path_prefix path', $path, 0);
    _require_path_string('replace_path_prefix source prefix', $from, 0);
    _require_path_string('replace_path_prefix replacement', $to, 0);

    return _replace_path_prefix_with_spec(
        'File::Spec', $path, $from, $to,
    );
}

sub _same_path_component {
    my ($left, $right, $spec_class) = @_;
    $spec_class ||= 'File::Spec';
    return 0 unless defined $left && defined $right;
    return lc($left) eq lc($right) if $spec_class->case_tolerant;
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

# True if $x is a nominal PAGI::Response value. Production Responses receive
# ($scope, $receive, $send).
# The single source of truth for the "did the handler return a response?" check
# (used by the endpoint and router dispatch paths).
sub is_response {
    my ($x) = @_;
    return blessed($x) && $x->isa('PAGI::Response') ? 1 : 0;
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
    my ($value) = @_;
    _validate_app_value($value, 'to_app() application');
    return $value if ref($value) eq 'CODE';
    my $app = $value->to_app;
    croak ref($value) . '->to_app must return a coderef'
        unless ref($app) eq 'CODE';
    return $app;
}

sub as_app {
    my ($code) = @_;
    croak 'as_app() requires a native coderef'
        unless ref($code) eq 'CODE';
    return PAGI::Utils::_App->new($code);
}

async sub invoke_app {
    my ($value, $scope, $receive, $send) = @_;
    my $app = to_app($value);
    my $returned = $app->($scope, $receive, $send);
    return await Future->wrap($returned);
}

sub _validate_app_value {
    my ($value, $label) = @_;
    $label = 'application' unless defined $label && length $label;

    if (blessed($value) && $value->can('wrap') && !$value->can('to_app')) {
        croak "$label middleware object is not an app";
    }

    croak "$label must be a coderef or instantiated object with to_app"
        unless defined $value
            && (ref($value) eq 'CODE'
                || (blessed($value) && $value->can('to_app')));
    return $value;
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

    use PAGI::Utils qw(:path);

    my $file = path_from_root($document_root, $request_path);
    if (defined $file) {
        my $uri = replace_path_prefix($file, $document_root, '/protected');
        ...
    }

    use PAGI::Utils qw(:env);

    if (is_development()) {
        # Development-only configuration.
    }

=head1 FUNCTIONS

=head2 pagi_env

    use PAGI::Utils qw(:env);

    my $environment = pagi_env();

Returns the current C<PAGI_ENV>. The only accepted nonempty values are
C<development>, C<test>, C<staging>, and C<production>. An unset or empty
C<PAGI_ENV> safely defaults to C<production>; any other nonempty value croaks.
The environment is read dynamically on every call rather than cached. This
zero-argument function croaks if passed arguments.

=head2 is_development

    use PAGI::Utils qw(:env);

    if (is_development()) { ... }

Returns true when C<pagi_env()> is C<development>. It uses the same dynamic,
strict C<PAGI_ENV> contract as C<pagi_env()> and accepts no arguments.

=head2 is_test

    use PAGI::Utils qw(:env);

    if (is_test()) { ... }

Returns true when C<pagi_env()> is C<test>. It uses the same dynamic, strict
C<PAGI_ENV> contract as C<pagi_env()> and accepts no arguments.

=head2 is_staging

    use PAGI::Utils qw(:env);

    if (is_staging()) { ... }

Returns true when C<pagi_env()> is C<staging>. It uses the same dynamic,
strict C<PAGI_ENV> contract as C<pagi_env()> and accepts no arguments.

=head2 is_production

    use PAGI::Utils qw(:env);

    if (is_production()) { ... }

Returns true when C<pagi_env()> is C<production>. It uses the same dynamic,
strict C<PAGI_ENV> contract as C<pagi_env()> and accepts no arguments.

=head2 EXPORTS

C<:env> exports exactly C<pagi_env>, C<is_development>, C<is_test>,
C<is_staging>, and C<is_production>. C<:path> exports exactly C<app_path>,
C<path_from_root>, and C<replace_path_prefix>. C<:all> exports every optional
helper in C<PAGI::Utils>.

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

=head2 path_from_root

    use PAGI::Utils qw(path_from_root);

    my $file = path_from_root($document_root, $request_path);
    return unless defined $file;

Builds an absolute, platform-native filesystem path from a root and an HTTP-like
request path. It splits both slash styles into logical components, ignores empty
and C<.> components, and rejects traversal components (C<..> and longer
all-dot components), NUL bytes, and components that are absolute or volumed on
the current platform. Unsafe request content returns C<undef>; an undefined,
reference-valued, or empty root, or an undefined or reference-valued request
path, is a programmer error and croaks.

A final slash or C<.> retains directory intent by appending the native current
directory component. The function performs no I/O, does not require the result
to exist, and neither resolves symlinks nor claims to enforce a symlink
sandboxing policy.

=head2 replace_path_prefix

    use PAGI::Utils qw(replace_path_prefix);

    my $uri = replace_path_prefix($file, $document_root, '/protected');
    return unless defined $uri;

Returns a slash-separated path formed by replacing an exact filesystem path
prefix with C<$to>. Matching is component-aware after platform-native absolute
normalization, so a sibling such as C</srv/files-old> does not match a prefix
of C</srv/files>. It returns C<undef> when C<$path> is not C<$from> or a
descendant, including paths on different volumes. Undefined, empty, or
reference-valued arguments are programmer errors and croak.

The helper performs no I/O and does not resolve or apply policy to symlinks.

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

=back

Application positions accept native coderefs and instantiated component objects
only. They never load package names. Anything else croaks. A middleware object
(something with C<wrap> but no C<to_app>) gets a middleware-specific croak,
since middleware belongs in middleware position, not app position.

All composition points in this distribution (builder mounts, router
targets, cascades, the test client) call this for you, so user code can pass
native apps and instantiated components directly:

    mount '/static' => PAGI::App::File->new(root => $dir);
    mount '/api'    => MyApp::API->new;

Middleware positions have a separate explicit class-loading contract; pass a
middleware class name there, not in an application position.

=cut

=head2 is_response

    croak "handler did not return a response" unless is_response($value);

Returns 1 if C<$value> is a nominal L<PAGI::Response> value (including a
subclass) and 0 otherwise. Objects that merely implement C<respond> or C<to_app>
are application adapters, not Response values. This is the single source of
truth for the "did the handler return a response?" check used across the
endpoint and router dispatch paths, so those checks stay consistent (same
predicate, same C<croak> diagnostics) instead of each re-deriving the nominal
check.

=cut
