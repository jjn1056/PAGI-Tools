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
use overload ();
use PAGI::Lifespan;
use PAGI::Utils::AppObject;
use PAGI::Utils::Headers ();

my @PAGI_ENVIRONMENTS = qw(development test staging production);
my %VALID_PAGI_ENV = map { $_ => 1 } @PAGI_ENVIRONMENTS;
my @ENV_EXPORTS = qw(
    pagi_env is_development is_test is_staging is_production
);
my @PATH_EXPORTS = qw(
    app_path path_from_root replace_path_prefix
);

our @EXPORT_OK = (
    qw(handle_lifespan to_app as_app_object invoke_app
       request_ended_abnormally),
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

sub request_ended_abnormally {
    my ($scope) = @_;
    return 0 unless ref($scope) eq 'HASH';

    my $connection = $scope->{'pagi.connection'};
    return 0 unless blessed($connection)
        && $connection->can('disconnect_reason');

    my $reason = $connection->disconnect_reason;
    return defined($reason) && length($reason) ? 1 : 0;
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

sub as_app_object {
    croak 'as_app_object() requires exactly one native coderef or app object'
        unless @_ == 1;
    my ($value) = @_;
    return PAGI::Utils::AppObject->new($value)
        if ref($value) eq 'CODE';
    if (blessed($value) && $value->can('to_app')) {
        Carp::carp(
            'as_app_object() received an app object; returning it unchanged'
        );
        return $value;
    }
    croak 'as_app_object() requires exactly one native coderef or app object';
}

async sub invoke_app {
    my ($value, $scope, $receive, $send) = @_;
    return await Future->wrap(to_app($value)->($scope, $receive, $send));
}

# Resolve a short class name the way middleware() does: a leading '+' names
# an exact package, a name already under $namespace is kept, and anything else
# is prefixed with "$namespace::". $what names the kind of class in errors.
# The string a blessed object gives when its class overloads stringification,
# or the value unchanged. The overload is called directly, once: it may return
# undef, which callers refuse, and "$value" would warn about that. Objects that
# overload only numeric or boolean conversion are not strings and pass through
# unchanged, to be refused by the caller.
sub _stringified {
    my ($value) = @_;
    return $value unless blessed($value);
    my $method = overload::Method($value, '""') or return $value;
    return $method->($value, undef, '');
}

# $value as a plain string, stringifying an object that overloads "", or
# undef when it is not one. Callers croak with their own message, so the
# error names the caller's line.
sub _string_value {
    my $value = _stringified($_[0]);
    return defined($value) && !ref($value) ? $value : undef;
}

# $value as plain bytes, or undef when it holds a character above 0xFF.
# Bytes are every character <= 0xFF: Perl's internal UTF-8 flag says how a
# string is stored, not whether it is text, so it is not consulted. The copy
# is downgraded (a no-op for a string that is not flagged), so what is sent
# is one representation. Never a bare utf8::downgrade, which dies on a wide
# character.
sub _byte_string {
    my ($value) = @_;
    my $bytes = $value;
    return utf8::downgrade($bytes, 1) ? $bytes : undef;
}

# A header value as Tools may send it: an object whose class overloads ""
# stands for its string, and the value must be bytes. Returns the bytes, or
# (undef, 'not a string') or (undef, 'wide'), so each caller croaks with its
# own message at its caller's line. PAGI::Headers itself stays a plain
# container, as request headers live in it too.
sub _sendable_header_value {
    my $value = _stringified($_[0]);
    return (undef, 'not a string') unless defined $value && !ref($value);
    my $bytes = _byte_string($value);
    return defined($bytes) ? ($bytes) : (undef, 'wide');
}

# Undef for a header name Tools may send (an HTTP token, RFC 9110), or why
# not, with unprintable characters escaped so the message itself is safe.
sub _header_name_refusal {
    my ($name) = @_;
    return undef if PAGI::Utils::Headers::_is_http_token($name);
    (my $shown = $name // '') =~ s/([^\x20-\x7E])/sprintf '\\x{%X}', ord $1/ge;
    return "header name '$shown' must be an HTTP token";
}

# A headers argument in any of its three shapes -- a flat [name => value]
# list, [[name, value]] pairs as the PAGI spec writes headers, or a
# PAGI::Headers object -- as a new list of [name, value] pairs. Returns the
# pairs, or (undef, $message) for anything else, so the site croaks at its
# caller's line. Values are not checked here.
sub _header_pairs {
    my ($label, $headers) = @_;
    my $refused = "$label headers must be a flat [name => value] list, [[name, value]] pairs, or a PAGI::Headers object";
    return ($headers->to_pairs) if blessed($headers) && $headers->isa('PAGI::Headers');
    return (undef, $refused) unless ref($headers) eq 'ARRAY';
    if (@$headers && ref($headers->[0]) eq 'ARRAY') {
        return (undef, $refused)
            if grep { ref($_) ne 'ARRAY' || @$_ != 2 || !defined($_->[0]) || ref($_->[0]) } @$headers;
        return ([ map { [@$_] } @$headers ]);
    }
    my @names = map { $headers->[$_] } grep { $_ % 2 == 0 } 0 .. $#$headers;
    return (undef, $refused) if @$headers % 2 || grep { !defined($_) || ref($_) } @names;
    return ([ map { [ @{$headers}[$_, $_ + 1] ] } grep { $_ % 2 == 0 } 0 .. $#$headers ]);
}

# Headers as Tools sends them in an event: any of the three shapes, every
# name an HTTP token and every value by the one rule. Returns the pairs, or (undef, $message).
sub _sendable_headers {
    my ($label, $headers) = @_;
    my ($pairs, $refused) = _header_pairs($label, $headers);
    return (undef, $refused) if $refused;
    for my $pair (@$pairs) {
        if (defined(my $refused = _header_name_refusal($pair->[0]))) {
            return (undef, $refused);
        }
        my ($bytes, $not) = _sendable_header_value($pair->[1]);
        return (undef, $not eq 'wide'
            ? "header '$pair->[0]' value contains a character above 0xFF: encode it first"
            : "header '$pair->[0]' value must be a string or an object that overloads stringification")
            if $not;
        $pair->[1] = $bytes;
    }
    return ($pairs);
}

sub _resolve_class {
    my ($namespace, $name, $what) = @_;
    croak "invalid $what class name; use leading '+' for an exact package"
        unless defined $name && !ref $name
            && $name =~ /\A\+?[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*\z/;
    return substr($name, 1) if substr($name, 0, 1) eq '+';
    return $name if $name eq $namespace || index($name, "${namespace}::") == 0;
    return "${namespace}::$name";
}

# A first-party component's `refuse` option: undef when the caller gave
# none (the component uses its own default), the string '0' when the caller
# asked the application to decide (only if $may_decide), else the caller's
# application as a native coderef (a bare coderef given is run as a Request
# handler). Any other plain value dies: an undefined or
# mistyped setting must never switch a check off.
sub _refuse_option {
    my ($component, $config, $may_decide) = @_;
    return _application_option($component, $config, 'refuse', $may_decide);
}

# A PAGI-Tools middleware's last step in _init: an option it does not know is
# a misspelling or a renamed option, and is never silently ignored. Run after
# the middleware's own checks, so an option it removed keeps its own message.
sub _reject_unknown_options {
    my ($name, $config, @known) = @_;
    my %known = map { $_ => 1 } @known;
    for my $key (sort keys %$config) {
        croak "$name has unknown option '$key'" unless $known{$key};
    }
    return;
}

# The same for any option whose value replaces a component's own response,
# such as Maintenance's `response`.
sub _application_option {
    my ($component, $config, $key, $may_decide) = @_;
    return undef unless exists $config->{$key};
    my $value = $config->{$key};
    return '0' if $may_decide && defined($value) && !ref($value) && $value eq '0';
    die $may_decide
        ? "$component '$key' must be an application, or 0 to let the application decide"
        : "$component '$key' must be an application"
        unless ref($value);
    # The option answers a request, so a bare coderef is a Request handler, as
    # at a Route; as_app_object() passes a native application.
    if (ref($value) eq 'CODE') {
        require PAGI::Routing::RequestResponse;
        return PAGI::Routing::RequestResponse->new(handler => $value)->to_app;
    }
    return to_app($value);
}

# True when $package already has symbols of its own (a sub, a variable,
# @ISA): it was declared inline or loaded, so it must not be required, since
# a package defined in app.pl has no file. A stash that holds only nested
# packages (MyApp:: when only MyApp::Request is loaded) does not count. The
# walk starts at %main:: so the check itself creates no stash.
sub _package_is_defined {
    my ($package) = @_;
    my $stash = \%main::;
    for my $part (split /::/, $package) {
        my $glob = $stash->{"${part}::"};
        return 0 unless defined($glob) && ref(\$glob) eq 'GLOB';
        $stash = *{$glob}{HASH};
    }
    return grep({ !/::\z/ } keys %$stash) ? 1 : 0;
}

# The one way PAGI-Tools loads a class it is given by name. Returns undef
# once $class can be used, or the message to die with, which begins with
# $caller (the call as the user wrote it, such as "response('JSON')").
#
# A class that is already defined -- declared in app.pl, or loaded -- and
# that $usable accepts is used as it is: a class declared in app.pl has no
# file. Otherwise its file is required. A class whose file died while
# loading is never used as it is, though it may have defined enough to look
# usable. A package that is defined but has no file, and that $usable
# refused (a name compiled code mentioned), is left for the caller's own
# check to report.
sub _load_class {
    my ($class, $caller, $usable, $given) = @_;
    (my $file = "$class.pm") =~ s{::}{/}g;
    my $failed = exists($INC{$file}) && !defined($INC{$file});
    my $defined = !$failed && _package_is_defined($class);
    return undef if $defined && $usable->($class);
    return "$caller: cannot load $class: no file named exactly $file in \@INC"
        unless _file_name_matches_case($file);
    return undef if eval { require $file; 1 };
    # require's own " at FILE line N." names this line, not the caller's.
    (my $error = $@) =~ s/ at \S+ line \d+\.\n\z//;
    return undef if $defined && $error =~ /\ACan't locate \Q$file\E in \@INC/;
    # A short name with :: that was prefixed and not found was most likely
    # meant as a package name of its own.
    return "$caller: cannot load $class: no file $file in \@INC;"
        . " for the package $given itself, write '+$given'"
        if defined($given) && $given =~ /::/ && substr($given, 0, 1) ne '+'
            && $given ne $class && $error =~ /\ACan't locate \Q$file\E in \@INC/;
    return "$caller: cannot load $class: $error";
}

# A Moose class extending a non-Moose base keeps the base's new, so its
# required, default and BUILD would be silently ignored. Returns the message,
# naming $label, or undef; the caller croaks it, so the error names the
# caller's caller. The can('meta') gate keeps Moo classes out: with Moose
# loaded, a Moo class's metaclass also answers isa('Moose::Meta::Class').
sub _moose_constructor_error {
    my ($class, $label) = @_;
    return undef unless $INC{'Moose.pm'} && $class->can('meta');
    my $meta = eval { $class->meta };
    return undef unless blessed($meta) && $meta->isa('Moose::Meta::Class');
    return undef if $class->isa('Moose::Object');
    return "$label is a Moose class whose new is not Moose's, so its"
        . ' attributes (required, default, BUILD) would be ignored; add'
        . ' "use MooseX::NonMoose" after "use Moose"';
}

# On a case-insensitive filesystem, require 'Foo/json.pm' opens Foo/JSON.pm
# and compiles it a second time under a package name it does not define.
# True when every component of the first @INC match has exactly this case,
# or when no directory has the file (require then reports it).
sub _file_name_matches_case {
    my ($relative) = @_;
    for my $dir (grep { defined && !ref } @INC) {
        next unless -e "$dir/$relative";
        my $path = $dir;
        for my $part (split m{/}, $relative) {
            opendir(my $dh, $path) or return 1;
            my $exact = grep { $_ eq $part } readdir $dh;
            closedir $dh;
            return 0 unless $exact;
            $path .= "/$part";
        }
        return 1;
    }
    return 1;
}

sub _validate_app_value {
    my ($value, $label, $coderef_role) = @_;
    $label = 'application' unless defined $label && length $label;
    $coderef_role = 'native coderef'
        unless defined $coderef_role && length $coderef_role;

    if (blessed($value) && $value->can('wrap') && !$value->can('to_app')) {
        croak "$label middleware object is not an app";
    }

    my $separator = $label =~ /:\z/ ? ' ' : ' must be ';
    croak "$label${separator}a $coderef_role or app object "
        . '(an instantiated object with to_app)'
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

=head2 request_ended_abnormally

    return if request_ended_abnormally($scope);

True when this request ended B<abnormally> -- the client disconnected, a
timeout fired, or the server aborted the exchange -- and false otherwise,
including for a request that completed cleanly, one still in flight, and a
scope carrying no C<pagi.connection> object.

The discriminator is a defined C<disconnect_reason>, B<not> C<is_connected>:
a clean completion also reports false for C<is_connected>, and those
responses must still be validated. See L<PAGI::Spec::Www/"Application Left a
Response Incomplete">.

Components that observe response events use this to tell a spec-legal
disconnect from an application fault. They cannot tell them apart from the
event stream alone: an application that stops early because its client
vanished is required B<not> to send the terminal event, so its stream is
indistinguishable from a buggy one. An observer that infers completeness
from events must therefore ask the request.

Anything that emits response events on an application's behalf -- middleware
that buffers a body and re-emits it, or any intermediary wrapping C<$send> --
must not complete an incomplete stream, and must not compute a validator, a
C<Content-Length>, or other completeness-dependent metadata from the bytes it
happened to observe.

=head2 to_app

    use PAGI::Utils qw(to_app);

    my $app = to_app($thing);

Coerce C<$thing> into a native PAGI application coderef. An B<app object> is
an instantiated object with a C<to_app> method that returns such a coderef.
This is the common term used throughout PAGI-Tools for that object form.

C<to_app> accepts:

=over 4

=item * a coderef - returned unchanged

=item * an app object - compiled by calling its C<to_app> method

=back

Application positions accept native coderefs and app objects only. They never
load package names. Anything else croaks. A middleware object
(something with C<wrap> but no C<to_app>) gets a middleware-specific croak,
since middleware belongs in middleware position, not app position.

Mount C<app> is Routing's native application position, so it calls this for
native apps and app objects directly. Router C<http_default> bare CODE is a
one-Request handler; wrap an advanced native default with
C<as_app_object>. Cascades and the test client likewise normalize their
application input. Compose is different: it accepts route declarations only
through C<routes>. Preserve an immutable Router explicitly as a Mount C<app>
within that list.

    mount('/static', app => PAGI::App::File->new(root => $dir));
    mount('/api',    app => MyApp::API->new);

A Route is the exceptional adapter boundary: it accepts either a one-argument
Request, WebSocket, or SSE handler or an app object. A bare CODE is the handler;
the app object is a native application endpoint.

=head2 as_app_object

    use PAGI::Utils qw(as_app_object);

    route('/native' => as_app_object($native));
    route('/relay' => as_app_object($native), methods => '*');
    await $ws->deny(as_app_object($native));
    await $sse->decline(as_app_object($native));

Given a native application coderef, returns a
L<PAGI::Utils::AppObject> whose C<to_app> returns that exact coderef. Given an
existing app object, warns and returns that same object unchanged. It does not
inspect arity, alter Future behavior, capture a scope, or add protocol policy.
At an HTTP Route, no explicit methods means GET plus automatic HEAD; scalar
C<< methods => '*' >> is unrestricted.

Use C<as_app_object> to pass a native C<($scope, $receive, $send)> application
where a bare coderef would otherwise be interpreted as a handler. This
includes Route endpoints, WebSocket C<deny>, and SSE C<decline>. Ordinary
handler callbacks do not need the wrapper.

The wrapper's C<to_app> returns the original native coderef. It does not change
the scope, receive or send channel, events, or application lifecycle behavior.

=head2 invoke_app

    use Future::AsyncAwait;
    use PAGI::Pages ();
    use PAGI::Utils qw(invoke_app);

    return await invoke_app(
        PAGI::Pages->welcome,
        $scope,
        $receive,
        $send,
    );

C<invoke_app> is a convenience for native three-argument PAGI code that needs
to execute an application value. The example above is equivalent to:

    my $app = PAGI::Pages->welcome->to_app;

    return await Future->wrap(
        $app->($scope, $receive, $send)
    );

This is useful in a native PAGI application or middleware that wants to emit a
L<PAGI::Response>, a L<PAGI::Pages> result, or another app object without
open-coding the C<to_app> and immediate-or-Future handling:

    sub require_auth ($app) {
        return async sub ($scope, $receive, $send) {
            unless (authorized($scope)) {
                return await invoke_app(
                    PAGI::Pages->unauthorized(
                        detail => 'Please sign in',
                    ),
                    $scope,
                    $receive,
                    $send,
                );
            }

            return await Future->wrap(
                $app->($scope, $receive, $send)
            );
        };
    }

A normal one-argument Request handler does not need C<invoke_app>. It returns
the application value and lets the Route adapter execute it:

    sub handler ($request) {
        return PAGI::Pages->not_found(
            detail => 'No such page',
        );
    }

Normalizes C<$value> through C<to_app>, invokes it with the exact supplied
triplet, and awaits immediate or Future-backed completion. It installs no HEAD,
scope-rewrite, response-completion, error, or lifespan policy. Use this at a
native triplet boundary instead of a Response-specific emission method.

Middleware positions have a separate explicit class-loading contract; pass a
middleware class name there, not in an application position.

=cut
