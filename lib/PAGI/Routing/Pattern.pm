package PAGI::Routing::Pattern;

use strict;
use warnings;
use Carp qw(croak);
use Encode qw(encode FB_CROAK);
use Scalar::Util qw(blessed);

sub new {
    my ($class, @args) = @_;
    my $declaration_package = caller;
    return $class->_new_from($declaration_package, @args);
}

sub _new_from {
    my ($class, $default_declaration_package, @args) = @_;
    croak 'pattern option list must be key/value pairs' if @args % 2;
    my %args = @args;

    my %allowed = map { $_ => 1 }
        qw(path mode constraints declaration_package _predicate_records);
    for my $key (keys %args) {
        croak "unknown pattern option '$key'" unless $allowed{$key};
    }

    my $path = $args{path};
    my $mode = $args{mode};
    my $constraints = $args{constraints};
    my $declaration_package = exists $args{declaration_package}
        ? $args{declaration_package}
        : $default_declaration_package;
    my $has_predicate_records = exists $args{_predicate_records};
    my $predicate_records = $args{_predicate_records};

    croak 'path must be a string' unless defined $path && !ref($path);
    croak "path must begin with '/'" unless substr($path, 0, 1) eq '/';
    croak "pattern mode must be 'route' or 'mount'"
        unless defined $mode && !ref($mode) && ($mode eq 'route' || $mode eq 'mount');
    croak 'constraints must be a hashref' unless ref($constraints) eq 'HASH';
    croak 'declaration_package must be a Perl package name'
        unless defined $declaration_package && !ref($declaration_package)
            && $declaration_package =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*\z/;
    croak '_predicate_records must be a hashref'
        if $has_predicate_records && ref($predicate_records) ne 'HASH';
    croak 'pre-normalized predicate records cannot be combined with constraints'
        if $has_predicate_records && keys %$constraints;

    if ($mode eq 'mount' && length($path) > 1 && substr($path, -1) eq '/') {
        chop $path;
    }

    my @tokens;
    my @names;
    my %seen;
    my $wildcards = 0;
    my $literal = '';
    my $position = 0;

    while ($position < length $path) {
        my $remaining = substr($path, $position);
        my ($name, $inline, $token_text);

        my $inline_token = _scan_inline_parameter($path, $position);
        if ($inline_token) {
            ($name, $inline, $token_text) = @{$inline_token}{qw(name source token_text)};
            _push_literal(\@tokens, \$literal);
            _reject_duplicate(\%seen, $name);
            my $token = {
                kind       => 'parameter',
                name       => $name,
                predicates => [],
            };
            push @{$token->{predicates}},
                _compile_inline_constraint($name, $inline, $declaration_package)
                unless $has_predicate_records;
            push @tokens, $token;
            push @names, $name;
            $position += length $token_text;
            next;
        }

        if ($remaining =~ /\A\{([A-Za-z_][A-Za-z0-9_]*)\}/) {
            ($name, $token_text) = ($1, $&);
            _push_literal(\@tokens, \$literal);
            _reject_duplicate(\%seen, $name);
            push @tokens, {
                kind       => 'parameter',
                name       => $name,
                predicates => [],
            };
            push @names, $name;
            $position += length $token_text;
            next;
        }

        if ($remaining =~ /\A:([A-Za-z_][A-Za-z0-9_]*)/) {
            ($name, $token_text) = ($1, $&);
            _push_literal(\@tokens, \$literal);
            _reject_duplicate(\%seen, $name);
            push @tokens, {
                kind       => 'parameter',
                name       => $name,
                predicates => [],
            };
            push @names, $name;
            $position += length $token_text;
            next;
        }

        if (substr($remaining, 0, 1) eq '*') {
            croak 'wildcard must occupy a whole segment'
                unless $remaining =~ /\A\*([A-Za-z_][A-Za-z0-9_]*)/;
            ($name, $token_text) = ($1, $&);
            my $token_end = $position + length($token_text);
            my $before = $position ? substr($path, $position - 1, 1) : '';
            my $after = $token_end < length($path) ? substr($path, $token_end, 1) : '';
            croak 'wildcard must occupy a whole segment'
                unless $before eq '/' && ($after eq '' || $after eq '/');
            croak 'mount paths do not allow wildcards' if $mode eq 'mount';
            croak 'only one wildcard is allowed' if $wildcards++;
            croak 'wildcard must be terminal' unless $token_end == length($path);
            _push_literal(\@tokens, \$literal);
            _reject_duplicate(\%seen, $name);
            push @tokens, {
                kind       => 'wildcard',
                name       => $name,
                predicates => [],
            };
            push @names, $name;
            $position = $token_end;
            next;
        }

        $literal .= substr($path, $position, 1);
        $position++;
    }
    _push_literal(\@tokens, \$literal);

    my %by_name = map { $_->{name} => $_ } grep { $_->{kind} ne 'literal' } @tokens;
    if ($has_predicate_records) {
        _install_predicate_records(\%by_name, \@names, $predicate_records);
    }
    else {
        for my $name (sort keys %$constraints) {
            croak "constraint '$name' does not name a path parameter"
                unless exists $by_name{$name};
            push @{$by_name{$name}{predicates}},
                _normalize_constraint($name, $constraints->{$name});
        }
    }

    my %stored_predicates = map {
        my $name = $_;
        $name => [map { +{%$_} } @{$by_name{$name}{predicates}}]
    } @names;

    my @fragments;
    for my $token (@tokens) {
        if ($token->{kind} eq 'literal') {
            push @fragments, quotemeta($token->{value});
        }
        elsif ($token->{kind} eq 'parameter') {
            push @fragments, '([^/]+)';
        }
        else {
            push @fragments, '((?s:.*))';
        }
    }
    my $path_source = join('', @fragments);
    my $matcher = $mode eq 'route'
        ? qr/\A(?:$path_source)\z/
        : $path eq '/'
            ? qr/\A/
            : qr/\A(?:$path_source)(?=\/|\z)/;

    return bless {
        path        => $path,
        mode        => $mode,
        constraints => { %$constraints },
        predicate_records => \%stored_predicates,
        tokens      => \@tokens,
        parameters  => \@names,
        matcher     => $matcher,
    }, $class;
}

sub _scan_inline_parameter {
    my ($path, $position) = @_;
    my $remaining = substr($path, $position);
    return unless $remaining =~ /\A\{([A-Za-z_][A-Za-z0-9_]*):/;

    my $name = $1;
    my $source_start = $position + length($&);
    my $cursor = $source_start;
    my $brace_depth = 0;
    my $in_class = 0;
    my $class_initial = 0;
    my $class_special;
    my $in_comment = 0;

    while ($cursor < length $path) {
        my $character = substr($path, $cursor, 1);

        if ($in_comment) {
            $in_comment = 0 if $character eq ')';
            $cursor++;
            next;
        }

        if ($character eq '\\') {
            $class_initial = 0 if $in_class;
            $cursor += $cursor + 1 < length($path) ? 2 : 1;
            next;
        }

        if ($in_class) {
            if (defined $class_special) {
                if ($character eq $class_special
                        && $cursor + 1 < length($path)
                        && substr($path, $cursor + 1, 1) eq ']') {
                    $cursor += 2;
                    $class_special = undef;
                }
                else {
                    $cursor++;
                }
                next;
            }

            if ($character eq '[' && $cursor + 1 < length($path)) {
                my $delimiter = substr($path, $cursor + 1, 1);
                if ($delimiter eq ':' || $delimiter eq '.' || $delimiter eq '=') {
                    $class_special = $delimiter;
                    $class_initial = 0;
                    $cursor += 2;
                    next;
                }
            }
            if ($character eq ']' && !$class_initial) {
                $in_class = 0;
                $cursor++;
                next;
            }
            if ($class_initial && $character eq '^') {
                $cursor++;
                next;
            }

            $class_initial = 0;
            $cursor++;
            next;
        }

        if ($character eq '[') {
            $in_class = 1;
            $class_initial = 1;
            $cursor++;
            next;
        }
        if (substr($path, $cursor, 3) eq '(?#') {
            $in_comment = 1;
            $cursor += 3;
            next;
        }
        if ($character eq '{') {
            $brace_depth++;
            $cursor++;
            next;
        }
        if ($character eq '}') {
            if ($brace_depth) {
                $brace_depth--;
                $cursor++;
                next;
            }

            return {
                name       => $name,
                source     => substr($path, $source_start, $cursor - $source_start),
                token_text => substr($path, $position, $cursor - $position + 1),
            };
        }

        $cursor++;
    }

    croak "unterminated inline constraint for '$name'";
}

sub _push_literal {
    my ($tokens, $literal_ref) = @_;
    return unless length $$literal_ref;
    push @$tokens, {
        kind     => 'literal',
        value    => $$literal_ref,
        rendered => _encode_literal_path($$literal_ref),
    };
    $$literal_ref = '';
}

sub _reject_duplicate {
    my ($seen, $name) = @_;
    croak "duplicate path parameter '$name'" if $seen->{$name}++;
}

sub _install_predicate_records {
    my ($by_name, $names, $records) = @_;

    for my $name (sort keys %$records) {
        croak "predicate records contain unknown path parameter '$name'"
            unless exists $by_name->{$name};
    }

    for my $name (@$names) {
        croak "predicate records are missing path parameter '$name'"
            unless exists $records->{$name};
        croak "predicate records for '$name' must be an arrayref"
            unless ref($records->{$name}) eq 'ARRAY';

        my @copied;
        for my $record (@{$records->{$name}}) {
            croak "predicate record for '$name' requires a check coderef"
                unless ref($record) eq 'HASH' && ref($record->{check}) eq 'CODE';
            for my $field (sort keys %$record) {
                croak "predicate record for '$name' has unknown field '$field'"
                    unless $field eq 'check' || $field eq 'explain';
            }
            croak "predicate record for '$name' explain must be a coderef"
                if exists $record->{explain} && ref($record->{explain}) ne 'CODE';
            push @copied, { %$record };
        }
        $by_name->{$name}{predicates} = \@copied;
    }
}

sub _compile_inline_constraint {
    my ($name, $source, $declaration_package) = @_;
    return _compile_inline_regexp($name, $source)
        unless substr($source, 0, 1) eq '&';
    return _compile_inline_provider($name, $source, $declaration_package);
}

sub _compile_inline_provider {
    my ($name, $source, $declaration_package) = @_;

    my ($package_prefix, $function) = $source =~
        /\A&((?:[A-Za-z_][A-Za-z0-9_]*::)*)([A-Z][A-Za-z0-9_]*)\z/;
    unless (defined $function) {
        croak "invalid inline constraint provider '$source' for parameter '$name'; "
            . "expected '&' followed by a capitalized package function; "
            . "use '[&]' for a literal leading ampersand";
    }

    my $qualified = length($package_prefix) ? 1 : 0;
    $package_prefix =~ s/::\z// if $qualified;
    my $resolution_package = $qualified
        ? $package_prefix
        : $declaration_package;
    my $stash = _existing_stash($resolution_package);
    if (!$stash) {
        if ($qualified) {
            croak "inline constraint provider '$source' for parameter '$name' "
                . "cannot be resolved because package '$resolution_package' "
                . 'has no existing symbol table '
                . '(load the defining module before constructing routes)';
        }
        croak "inline constraint provider '$source' for parameter '$name' "
            . "is not defined in package '$resolution_package'";
    }

    my $provider;
    if (exists $stash->{$function}) {
        no strict 'refs';
        my $symbol = $resolution_package . '::' . $function;
        $provider = *{$symbol}{CODE};
    }
    croak "inline constraint provider '$source' for parameter '$name' "
        . "is not defined in package '$resolution_package'"
        unless $provider;

    my $value;
    my $completed = eval {
        $value = $provider->();
        1;
    };
    if (!$completed) {
        my $error = $@ || 'unknown provider error';
        chomp $error;
        croak "inline constraint provider '$source' for parameter '$name' "
            . "failed in package '$resolution_package': $error";
    }

    croak "inline constraint provider '$source' for parameter '$name' returned a Future"
        if blessed($value) && $value->isa('Future');

    my $invalid = "inline constraint provider '$source' for parameter '$name' "
        . 'must return a Regexp, coderef, or check object';
    return _normalize_constraint($name, $value, $invalid);
}

sub _existing_stash {
    my ($package) = @_;
    my $stash = \%main::;
    return $stash if $package eq 'main';

    no strict 'refs';
    for my $component (split /::/, $package) {
        my $key = $component . '::';
        return unless exists $stash->{$key};
        my $next = *{$stash->{$key}}{HASH};
        return unless $next;
        $stash = $next;
    }
    return $stash;
}

sub _compile_inline_regexp {
    my ($name, $source) = @_;
    my $regexp = eval { qr/\A(?:$source)\z/ };
    if (!$regexp) {
        my $error = $@ || 'unknown regex compilation error';
        chomp $error;
        croak "invalid inline constraint for '$name': $error";
    }
    return { check => sub { return $_[0] =~ $regexp ? 1 : 0 } };
}

sub _normalize_constraint {
    my ($name, $value, $invalid_message) = @_;

    if (ref($value) eq 'Regexp') {
        my $regexp = qr/\A(?:$value)\z/;
        return { check => sub { return $_[0] =~ $regexp ? 1 : 0 } };
    }
    if (ref($value) eq 'CODE') {
        return { check => $value };
    }
    if (blessed($value) && $value->can('check')) {
        my $record = {
            check => sub { return $value->check($_[0]) },
        };
        $record->{explain} = sub { return $value->get_message($_[0]) }
            if $value->can('get_message');
        return $record;
    }

    my $message = defined $invalid_message
        ? $invalid_message
        : "constraint '$name' must be a Regexp, coderef, or check object";
    croak $message;
}

sub match_route {
    my ($self, $path) = @_;
    croak 'match_route requires a route pattern' unless $self->{mode} eq 'route';
    my ($captures) = $self->_match($path);
    return $captures;
}

sub match_mount {
    my ($self, $path) = @_;
    croak 'match_mount requires a mount pattern' unless $self->{mode} eq 'mount';
    my ($captures, $consumed) = $self->_match($path);
    return unless defined $captures;

    my $remainder = substr($path, length($consumed));
    $remainder = '/' unless length $remainder;
    return {
        captures => $captures,
        consumed => $consumed,
        remainder => $remainder,
    };
}

sub _match {
    my ($self, $path) = @_;
    croak 'decoded path must be a string' unless defined $path && !ref($path);
    return unless $path =~ $self->{matcher};

    my $matched_end = $+[0];
    my @values;
    for my $capture_index (1 .. @{$self->{parameters}}) {
        push @values, substr($path, $-[$capture_index], $+[$capture_index] - $-[$capture_index]);
    }

    my %captures;
    my $value_index = 0;
    for my $token (@{$self->{tokens}}) {
        next if $token->{kind} eq 'literal';
        my $value = $values[$value_index++];
        return unless _predicates_accept($token, $value, undef);
        $captures{$token->{name}} = $value;
    }

    return (\%captures, substr($path, 0, $matched_end));
}

sub _predicates_accept {
    my ($token, $value, $render_label) = @_;

    for my $predicate (@{$token->{predicates}}) {
        my $accepted = $predicate->{check}->($value);

        croak 'route constraints must be synchronous; got Future'
            if blessed($accepted) && $accepted->isa('Future');
        next if $accepted;
        return 0 unless defined $render_label;

        my $message = "path parameter '$token->{name}' failed constraint for $render_label";
        if (exists $predicate->{explain}) {
            my $detail = $predicate->{explain}->($value);
            $message .= ": $detail" if defined $detail && length $detail;
        }
        croak $message;
    }
    return 1;
}

sub render {
    my ($self, $params, $route_name) = @_;
    my $label = defined $route_name && length $route_name
        ? "route '$route_name'"
        : "path '$self->{path}'";
    croak "path parameters for $label must be a hashref" unless ref($params) eq 'HASH';

    my %expected = map { $_ => 1 } @{$self->{parameters}};
    for my $name (@{$self->{parameters}}) {
        croak "missing path parameter '$name' for $label" unless exists $params->{$name};
        croak "path parameter '$name' for $label must be a defined scalar"
            unless defined $params->{$name} && !ref($params->{$name});
    }
    for my $name (sort keys %$params) {
        croak "unexpected path parameter '$name' for $label" unless $expected{$name};
    }

    my @parts;
    for my $token (@{$self->{tokens}}) {
        if ($token->{kind} eq 'literal') {
            push @parts, $token->{rendered};
            next;
        }

        my $value = $params->{$token->{name}};
        _predicates_accept($token, $value, $label);
        if ($token->{kind} eq 'wildcard') {
            push @parts, join('/', map { _encode_component($_) } split(m{/}, $value, -1));
        }
        else {
            push @parts, _encode_component($value);
        }
    }
    return join('', @parts);
}

sub _encode_literal_path {
    my ($value) = @_;
    return join('/', map { _encode_component($_) } split(m{/}, $value, -1));
}

sub _encode_component {
    my ($value) = @_;
    my $bytes = encode('UTF-8', $value, FB_CROAK);
    $bytes =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge;
    return $bytes;
}

sub path        { $_[0]->{path} }
sub parameters  { [ @{$_[0]->{parameters}} ] }
sub constraints { return { %{$_[0]->{constraints}} } }
sub _predicate_records {
    my ($self) = @_;
    return {
        map {
            my $name = $_;
            $name => [map { +{%$_} } @{$self->{predicate_records}{$name}}]
        } @{$self->{parameters}}
    };
}

1;

__END__

=head1 NAME

PAGI::Routing::Pattern - Compiled declarative routing path

=head1 DESCRIPTION

This internal routing value tokenizes a decoded declared path once, compiles
literal-safe matchers and synchronous constraint records, and retains tokens
for reverse URI rendering. Route matches are exact; mount matches consume a
segment-aligned prefix.

Construction validates and builds immutable matcher state at compile time and
does no protocol I/O. C<match_route> and C<match_mount> run against one
request's decoded path and return fresh capture hashes. C<render> validates
caller-supplied scalars and returns an escaped path string; it does not mutate
scope or emit events. C<parameters> and C<constraints> return defensive
top-level copies.

Regex and inline constraints are anchored with C<\A> and C<\z>. Predicates and
C<check> objects run synchronously during match or render, validate without
coercing, and may propagate exceptions. A Future result is rejected.

An inline source beginning with an unescaped C<&> is a constraint-provider
reference. Its capitalized package function is resolved as an exact CODE slot
in the direct declaration package, or in the already-loaded package named by a
qualified reference, and is called with no arguments during Pattern
construction. The result must be a regex, predicate coderef, or C<check>
object. C<[&]> is the canonical regex spelling for a literal leading
ampersand. Provider functions never run during matching or rendering.

All accepted constraint shapes become private C<check> coderefs with optional
failure explainers. Defensive copies of those records let composed reverse
patterns retain the source predicates without recompiling inline syntax or
renormalizing explicit constraints. Public C<constraints> continues to
describe only the explicit constructor option.

Inline tokenization recognizes ordinary regex comments C<(?#...)> but is not a
complete Perl regex parser. Complex patterns, particularly extended-mode
comments, should use an explicit C<constraints> regex.

=cut
