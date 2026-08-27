package PAGI::Pages;

use strict;
use warnings;

use Carp qw(croak);
use Encode qw(encode FB_CROAK);
use Future;
use HTTP::Date ();
use JSON::MaybeXS ();
use Scalar::Util qw(blessed);

use PAGI::Pages::_Catalog;
use PAGI::Request;
use PAGI::Request::Negotiate;
use PAGI::Response;

my %REPRESENTATION = map { $_ => 1 } qw(auto html json text);
my %DEFAULT_REPRESENTATION = map { $_ => 1 } qw(html json text);
my %WELCOME_OPTION = map { $_ => 1 } qw(as headers cache_control);
my %REDIRECT_OPTION = map { $_ => 1 } qw(
    as status detail headers cache_control preserve_query retry_after
);
my %ERROR_OPTION = map { $_ => 1 } qw(
    as detail type title instance extensions headers cache_control
    challenge allow length upgrade retry_after blocked_by login_url
);
my %PROBLEM_MEMBER = map { $_ => 1 } qw(type title status detail instance);
my %SEMANTIC_STATUS = (
    challenge   => { map { $_ => 1 } qw(401 407) },
    allow       => { 405 => 1 },
    length      => { 416 => 1 },
    upgrade     => { 426 => 1 },
    retry_after => { map { $_ => 1 } qw(413 429 503) },
    blocked_by  => { 451 => 1 },
    login_url   => { 511 => 1 },
);
my %RESPONSE_OWNED_FIELD = map { $_ => 1 } qw(
    content-type content-length transfer-encoding location cache-control
    connection
);
my %FORCED_NO_STORE = map { $_ => 1 } qw(428 429 431 511);
my %REDIRECT_STATUS = (
    301 => 'Moved Permanently',
    302 => 'Found',
    303 => 'See Other',
    307 => 'Temporary Redirect',
    308 => 'Permanent Redirect',
);

my $WELCOME_TITLE = 'Welcome to PAGI';
my $WELCOME_DETAIL = 'PAGI is a spiritual successor to PSGI for asynchronous Perl applications. '
    . 'It connects servers, frameworks, and applications across HTTP, WebSocket, and '
    . 'Server-Sent Events.';
my $WELCOME_LABEL = 'Read the PAGI documentation ' . chr(0x2192);
my $WELCOME_URL = 'https://metacpan.org/pod/PAGI';

my %FAVICON_COLOR = (
    2 => '#566f60',
    3 => '#566a78',
    4 => '#8a7743',
    5 => '#82505a',
);

sub new {
    my ($class, @args) = @_;
    my $opts = _flat_options('constructor', @args);

    for my $key (keys %$opts) {
        croak "PAGI::Pages constructor has unknown option '$key'"
            unless $key eq 'as' || $key eq 'default';
    }

    my $as = exists $opts->{as} ? $opts->{as} : 'auto';
    croak 'PAGI::Pages constructor as must be auto, html, json, or text'
        unless defined($as) && !ref($as) && length($as)
            && $REPRESENTATION{$as};

    my $default = exists $opts->{default} ? $opts->{default} : 'html';
    croak 'PAGI::Pages constructor default must be html, json, or text'
        unless defined($default) && !ref($default) && length($default)
            && $DEFAULT_REPRESENTATION{$default};

    return bless {
        as      => $as,
        default => $default,
    }, $class;
}

sub welcome {
    my ($proto, @args) = @_;
    my $self = _policy_for($proto);
    my $source = _take_request_source(\@args);
    my $opts = _normalize_options('welcome', \%WELCOME_OPTION, @args);
    my $factory = sub { return _welcome_descriptor($opts) };

    return $self->_response_for(_scope_from_source($source), $factory->())
        if defined $source;
    return $self->_endpoint($factory);
}

sub status {
    my ($proto, @args) = @_;
    my $self = _policy_for($proto);
    my $source = _take_request_source(\@args);
    my $status = shift @args;
    $status = _validated_status($status);
    my $opts = _normalize_options('error', \%ERROR_OPTION, @args);
    my $factory = _error_factory($status, $opts);

    return $self->_response_for(_scope_from_source($source), $factory->())
        if defined $source;
    return $self->_endpoint($factory);
}

sub redirect {
    my ($proto, @args) = @_;
    my $self = _policy_for($proto);
    my $source = _take_request_source(\@args);
    my $target = shift @args;
    my $opts = _normalize_options('redirect', \%REDIRECT_OPTION, @args);
    my $status = exists($opts->{status})
        ? _validated_redirect_status($opts->{status}) : 302;
    my $factory = _redirect_factory($target, $status, $opts);

    if (defined $source) {
        my $scope = _scope_from_source($source);
        return $self->_response_for($scope, $factory->($scope));
    }
    return $self->_endpoint($factory);
}

sub _invoke_named {
    my ($proto, $status, @args) = @_;
    my $self = _policy_for($proto);
    my $source = _take_request_source(\@args);
    my $opts = _normalize_options('error', \%ERROR_OPTION, @args);
    my $factory = _error_factory($status, $opts);

    return $self->_response_for(_scope_from_source($source), $factory->())
        if defined $source;
    return $self->_endpoint($factory);
}

sub _invoke_named_redirect {
    my ($proto, $status, @args) = @_;
    my $self = _policy_for($proto);
    my $source = _take_request_source(\@args);
    my $target = shift @args;
    my $opts = _normalize_options('redirect', \%REDIRECT_OPTION, @args);
    croak 'PAGI::Pages named redirect methods do not accept a status option'
        if exists $opts->{status};
    my $factory = _redirect_factory($target, $status, $opts);

    if (defined $source) {
        my $scope = _scope_from_source($source);
        return $self->_response_for($scope, $factory->($scope));
    }
    return $self->_endpoint($factory);
}

sub _policy_for {
    my ($proto) = @_;
    return $proto if blessed($proto) && $proto->isa('PAGI::Pages');
    croak 'PAGI::Pages invocant must be a Pages class or instance'
        if ref($proto);
    croak 'PAGI::Pages invocant must be a Pages class or instance'
        unless defined($proto) && $proto->isa('PAGI::Pages');
    return $proto->new;
}

sub _take_request_source {
    my ($args) = @_;
    return unless @$args;
    return unless _is_scope_candidate($args->[0])
        || _is_context_candidate($args->[0]);
    my $source = shift @$args;
    _scope_from_source($source);
    return $source;
}

sub _is_scope_candidate {
    my ($value) = @_;
    return ref($value) eq 'HASH' && !blessed($value);
}

sub _is_context_candidate {
    my ($value) = @_;
    return blessed($value) && $value->isa('PAGI::Context');
}

sub _scope_from_source {
    my ($source) = @_;
    my $scope = _is_context_candidate($source) ? $source->scope : $source;
    croak 'PAGI::Pages scope must be an unblessed hashref'
        unless ref($scope) eq 'HASH' && !blessed($scope);

    my $type = $scope->{type};
    croak 'PAGI::Pages scope type is required'
        unless defined($type) && !ref($type) && length($type);
    croak "PAGI::Pages requires HTTP scope; received '$type'"
        unless $type eq 'http';
    return $scope;
}

sub _endpoint {
    my ($self, $descriptor_factory) = @_;
    return sub {
        my @call = @_;

        if (@call && _is_context_candidate($call[0])) {
            my $scope = _scope_from_source($call[0]);
            return $self->_response_for($scope, $descriptor_factory->($scope));
        }

        if (@call && _is_scope_candidate($call[0])) {
            my $scope = _scope_from_source($call[0]);
            if (@call == 1) {
                return $self->_response_for($scope, $descriptor_factory->($scope));
            }
            if (@call == 3
                    && ref($call[1]) eq 'CODE'
                    && ref($call[2]) eq 'CODE') {
                my $response = $self->_response_for(
                    $scope, $descriptor_factory->($scope),
                );
                return Future->wrap($response->respond($call[2]));
            }
        }

        croak 'invalid PAGI::Pages endpoint invocation';
    };
}

sub _flat_options {
    my ($label, @args) = @_;
    croak "PAGI::Pages $label options must be key/value pairs" if @args % 2;

    my %opts;
    while (@args) {
        my ($key, $value) = splice(@args, 0, 2);
        croak "PAGI::Pages $label option names must be nonempty scalars"
            unless defined($key) && !ref($key) && length($key);
        $opts{$key} = $value;
    }
    return \%opts;
}

sub _normalize_options {
    my ($label, $allowed, @args) = @_;
    my $opts = _flat_options($label, @args);

    for my $key (keys %$opts) {
        croak "unknown PAGI::Pages $label option '$key'"
            unless $allowed->{$key};
    }

    if (exists $opts->{as}) {
        my $as = $opts->{as};
        croak 'PAGI::Pages as must be auto, html, json, or text'
            unless defined($as) && !ref($as) && length($as)
                && $REPRESENTATION{$as};
    }

    for my $key (qw(detail title)) {
        next unless exists $opts->{$key};
        croak "PAGI::Pages $key must be a Unicode scalar"
            unless defined($opts->{$key}) && !ref($opts->{$key});
    }

    _validate_absolute_problem_type($opts->{type})
        if exists $opts->{type};
    _validate_uri_reference('instance', $opts->{instance})
        if exists $opts->{instance};

    if (exists $opts->{extensions}) {
        croak 'PAGI::Pages extensions must be a hashref'
            unless ref($opts->{extensions}) eq 'HASH'
                && !blessed($opts->{extensions});
        for my $key (keys %{$opts->{extensions}}) {
            croak "PAGI::Pages extension '$key' is a reserved problem member"
                if $PROBLEM_MEMBER{$key};
        }
        my $copy = { %{$opts->{extensions}} };
        eval { JSON::MaybeXS::encode_json($copy); 1 }
            or croak "PAGI::Pages extensions must be JSON encodable: $@";
        $opts->{extensions} = $copy;
    }

    if (exists $opts->{headers}) {
        $opts->{headers} = _validate_headers($opts->{headers});
    }

    if (exists $opts->{cache_control}) {
        _validate_field_value('cache_control', $opts->{cache_control});
    }

    return $opts;
}

sub _validate_headers {
    my ($headers) = @_;
    croak 'PAGI::Pages headers must be an even-length arrayref [name => value, ...]'
        unless ref($headers) eq 'ARRAY' && @$headers % 2 == 0;

    my @copy = @$headers;
    for (my $index = 0; $index < @copy; $index += 2) {
        my ($name, $value) = @copy[$index, $index + 1];
        croak 'PAGI::Pages header name must be an HTTP token'
            unless defined($name) && !ref($name)
                && $name =~ /\A[!#\$%&'\*\+\-\.\^_\x60\|~0-9A-Za-z]+\z/;
        _validate_field_value("header '$name'", $value);
        my $lower = lc $name;
        croak "PAGI::Pages caller header '$name' is response-owned"
            if $RESPONSE_OWNED_FIELD{$lower};
    }
    return \@copy;
}

sub _validate_field_value {
    my ($label, $value) = @_;
    croak "PAGI::Pages $label must be a field-value scalar"
        unless defined($value) && !ref($value)
            && $value =~ /\A[\x20-\x7E]*\z/;
    return $value;
}

sub _validate_absolute_problem_type {
    my ($value) = @_;
    croak 'PAGI::Pages type must be an absolute URI'
        unless defined($value) && !ref($value)
            && $value =~ /\A[A-Za-z][A-Za-z0-9+.-]*:[\x21-\x7E]*\z/;
    croak 'PAGI::Pages type cannot be about:blank'
        if lc($value) eq 'about:blank';
    return $value;
}

sub _validate_uri_reference {
    my ($label, $value) = @_;
    croak "PAGI::Pages $label must be a URI-reference scalar"
        unless defined($value) && !ref($value)
            && $value =~ /\A[\x21-\x7E]*\z/;
    return $value;
}

sub _validated_status {
    my ($status) = @_;
    croak 'PAGI::Pages status must be an integer from 400 to 599'
        unless defined($status) && !ref($status)
            && $status =~ /\A[0-9]+\z/
            && $status >= 400 && $status <= 599;
    return 0 + $status;
}

sub _validated_redirect_status {
    my ($status) = @_;
    my $canonical = defined($status) && !ref($status) ? "$status" : undef;
    croak 'PAGI::Pages redirect status must be one of 301, 302, 303, 307, or 308'
        unless defined($canonical) && $canonical =~ /\A[0-9]+\z/
            && $REDIRECT_STATUS{$canonical};

    my $numeric = 0 + $status;
    croak 'PAGI::Pages redirect status must be one of 301, 302, 303, 307, or 308'
        unless $REDIRECT_STATUS{$numeric} && "$numeric" eq $canonical;
    return $numeric;
}

sub _welcome_descriptor {
    my ($opts) = @_;
    return {
        kind          => 'welcome',
        status        => 200,
        title         => $WELCOME_TITLE,
        detail        => $WELCOME_DETAIL,
        documentation => $WELCOME_URL,
        as            => $opts->{as},
        headers       => exists($opts->{headers}) ? [@{$opts->{headers}}] : [],
        cache_control => $opts->{cache_control},
    };
}

sub _redirect_factory {
    my ($target, $status, $opts) = @_;
    $target = _validate_uri_reference('redirect target', $target);
    my $prepared = _prepare_redirect_options($opts);
    my $detail = exists($opts->{detail})
        ? $opts->{detail} : 'The requested resource has moved.';

    return sub {
        my ($scope) = @_;
        my $location = _redirect_location($target, $scope,
            $prepared->{preserve_query});
        return {
            kind          => 'redirect',
            status        => $status,
            title         => $REDIRECT_STATUS{$status},
            detail        => $detail,
            location      => $location,
            as            => $opts->{as},
            headers       => [@{$prepared->{headers}}],
            cache_control => $prepared->{cache_control},
        };
    };
}

sub _prepare_redirect_options {
    my ($opts) = @_;
    my @headers = exists($opts->{headers}) ? @{$opts->{headers}} : ();

    if (exists $opts->{retry_after}) {
        croak 'PAGI::Pages redirect retry_after conflicts with raw Retry-After header'
            if _has_header(\@headers, 'Retry-After');
        push @headers, 'Retry-After' => _normalize_retry_after(
            $opts->{retry_after},
        );
    }

    my $preserve_query = exists($opts->{preserve_query})
        ? $opts->{preserve_query} : 0;
    croak 'PAGI::Pages preserve_query must be a Boolean scalar'
        unless defined($preserve_query) && !ref($preserve_query)
            && ($preserve_query eq '0' || $preserve_query eq '1');

    return {
        headers        => \@headers,
        cache_control  => $opts->{cache_control},
        preserve_query => $preserve_query ? 1 : 0,
    };
}

sub _redirect_location {
    my ($target, $scope, $preserve_query) = @_;
    return $target unless $preserve_query;
    my $query = $scope->{query_string};
    return $target unless defined($query) && !ref($query) && length($query);
    _validate_uri_reference('query_string', $query);

    my $fragment = '';
    my $fragment_at = index($target, '#');
    if ($fragment_at >= 0) {
        $fragment = substr($target, $fragment_at);
        $target = substr($target, 0, $fragment_at);
    }

    if (index($target, '?') < 0) {
        $target .= '?';
    }
    elsif (!(substr($target, -1, 1) eq '?'
            && index($target, '?') == length($target) - 1)) {
        $target .= '&';
    }
    return _validate_uri_reference('redirect target', $target . $query . $fragment);
}

sub _error_factory {
    my ($status, $opts) = @_;
    my $entry = PAGI::Pages::_Catalog->_entry($status);
    my $prepared = _prepare_error_options($status, $opts);
    my $extension_json = exists($opts->{extensions})
        ? JSON::MaybeXS::encode_json($opts->{extensions}) : undef;

    if ($entry) {
        my $has_type = exists $opts->{type};
        my $has_title = exists $opts->{title};
        croak 'PAGI::Pages type and title must be supplied together'
            if $has_type != $has_title;
    }
    else {
        croak "PAGI::Pages custom status $status requires type, title, and detail"
            unless exists($opts->{type})
                && exists($opts->{title})
                && exists($opts->{detail});
    }

    return sub {
        my $row = $entry
            ? { %$entry }
            : {
                status => $status,
                title  => $opts->{title},
                detail => $opts->{detail},
            };

        return {
            kind       => 'error',
            status     => $status,
            title      => exists($opts->{title}) ? $opts->{title} : $row->{title},
            detail     => exists($opts->{detail}) ? $opts->{detail} : $row->{detail},
            type       => exists($opts->{type}) ? $opts->{type} : 'about:blank',
            instance   => exists($opts->{instance}) ? $opts->{instance} : undef,
            extensions => defined($extension_json)
                ? JSON::MaybeXS::decode_json($extension_json) : {},
            as            => $opts->{as},
            headers       => [@{$prepared->{headers}}],
            cache_control => $prepared->{cache_control},
            login_url     => $prepared->{login_url},
            upgrade_connection => $prepared->{upgrade_connection},
        };
    };
}

sub _prepare_error_options {
    my ($status, $opts) = @_;

    for my $option (keys %SEMANTIC_STATUS) {
        next unless exists $opts->{$option};
        croak "PAGI::Pages semantic option '$option' is not valid for status $status"
            unless $SEMANTIC_STATUS{$option}{$status};
    }

    if ($status == 511 && exists($opts->{extensions})
            && exists($opts->{extensions}{login})) {
        croak "PAGI::Pages extension 'login' is a reserved problem member for status 511";
    }

    my @headers = exists($opts->{headers}) ? @{$opts->{headers}} : ();
    my @generated;

    if ($status == 401 || $status == 407) {
        my $name = $status == 401
            ? 'WWW-Authenticate' : 'Proxy-Authenticate';
        my @raw = _header_values(\@headers, $name);
        for my $value (@raw) {
            croak "PAGI::Pages $name challenge must be a nonempty scalar"
                unless $value =~ /\S/;
        }
        my $challenges = exists($opts->{challenge})
            ? _normalize_challenges($opts->{challenge}) : [];
        croak "PAGI::Pages status $status requires at least one $name challenge"
            unless @raw || @$challenges;
        push @generated, map { ($name => $_) } @$challenges;
    }

    if ($status == 405) {
        my $has_raw = _has_header(\@headers, 'Allow');
        croak 'PAGI::Pages status 405 Allow conflicts with raw Allow header'
            if exists($opts->{allow}) && $has_raw;
        if ($has_raw) {
            my $methods = _normalize_raw_token_field(
                \@headers, 'Allow', 1, 1,
            );
            @headers = @{_replace_header(\@headers, 'Allow', join(', ', @$methods))};
        }
        elsif (exists $opts->{allow}) {
            my $methods = _normalize_token_option('allow', $opts->{allow}, 1, 1);
            push @generated, Allow => join(', ', @$methods);
        }
        else {
            croak 'PAGI::Pages status 405 requires an Allow field';
        }
    }

    if ($status == 416 && exists $opts->{length}) {
        croak 'PAGI::Pages length conflicts with raw Content-Range header'
            if _has_header(\@headers, 'Content-Range');
        my $length = _normalize_nonnegative_integer('length', $opts->{length});
        push @generated, 'Content-Range' => 'bytes */' . $length;
    }

    if ($status == 426) {
        my $has_raw = _has_header(\@headers, 'Upgrade');
        croak 'PAGI::Pages upgrade conflicts with raw Upgrade header'
            if exists($opts->{upgrade}) && $has_raw;
        if ($has_raw) {
            my $protocols = _normalize_raw_token_field(
                \@headers, 'Upgrade', 0, 0,
            );
            @headers = @{_replace_header(
                \@headers, 'Upgrade', join(', ', @$protocols),
            )};
        }
        elsif (exists $opts->{upgrade}) {
            my $protocols = _normalize_token_option(
                'upgrade', $opts->{upgrade}, 0, 0,
            );
            push @generated, Upgrade => join(', ', @$protocols);
        }
        else {
            croak 'PAGI::Pages status 426 requires an Upgrade field';
        }
    }

    if (($status == 413 || $status == 429 || $status == 503)
            && exists $opts->{retry_after}) {
        croak 'PAGI::Pages retry_after conflicts with raw Retry-After header'
            if _has_header(\@headers, 'Retry-After');
        push @generated, 'Retry-After' => _normalize_retry_after(
            $opts->{retry_after},
        );
    }

    if ($status == 451 && exists $opts->{blocked_by}) {
        croak 'PAGI::Pages blocked_by conflicts with raw Link header'
            if _has_header(\@headers, 'Link');
        my $uri = _validate_uri_reference('blocked_by', $opts->{blocked_by});
        croak 'PAGI::Pages blocked_by contains a Link delimiter'
            if $uri =~ /[<>]/;
        push @generated, Link => '<' . $uri . '>; rel="blocked-by"';
    }

    my $login_url;
    if ($status == 511 && exists $opts->{login_url}) {
        $login_url = _validate_uri_reference('login_url', $opts->{login_url});
    }

    my $cache_control = exists($opts->{cache_control})
        ? $opts->{cache_control} : 'no-store';
    if ($FORCED_NO_STORE{$status}) {
        if (exists $opts->{cache_control}) {
            my $value = $opts->{cache_control};
            $value =~ s/\A +//;
            $value =~ s/ +\z//;
            croak "PAGI::Pages status $status cache_control must be no-store"
                unless lc($value) eq 'no-store';
        }
        $cache_control = 'no-store';
    }

    push @headers, @generated;
    return {
        headers            => \@headers,
        cache_control      => $cache_control,
        login_url          => $login_url,
        upgrade_connection => $status == 426 ? 1 : 0,
    };
}

sub _normalize_challenges {
    my ($value) = @_;
    my @values = ref($value) eq 'ARRAY' ? @$value : ($value);
    croak 'PAGI::Pages challenge must be a nonempty scalar or arrayref of challenges'
        unless (ref($value) eq 'ARRAY' || !ref($value)) && @values;
    for my $challenge (@values) {
        _validate_field_value('challenge', $challenge);
        croak 'PAGI::Pages challenge must be a nonempty scalar or arrayref of challenges'
            unless $challenge =~ /\S/;
    }
    return \@values;
}

sub _normalize_token_option {
    my ($label, $value, $uppercase, $allow_empty) = @_;
    my @values = ref($value) eq 'ARRAY' ? @$value : ($value);
    croak "PAGI::Pages $label must be a token or arrayref of tokens"
        unless ref($value) eq 'ARRAY' || !ref($value);
    return [] if $allow_empty && !@values;
    croak "PAGI::Pages $label must contain at least one token" unless @values;

    my (@normalized, %seen);
    for my $token (@values) {
        if ($allow_empty && @values == 1
                && defined($token) && !ref($token) && $token eq '') {
            return [];
        }
        croak "PAGI::Pages $label values must be HTTP tokens"
            unless _is_http_token($token);
        my $normalized = $uppercase ? uc($token) : $token;
        my $key = lc $normalized;
        push @normalized, $normalized unless $seen{$key}++;
    }
    return \@normalized;
}

sub _normalize_raw_token_field {
    my ($headers, $name, $uppercase, $allow_empty) = @_;
    my @parts;
    for my $value (_header_values($headers, $name)) {
        push @parts, split(/,/, $value, -1);
    }
    for my $part (@parts) {
        $part =~ s/\A +//;
        $part =~ s/ +\z//;
    }
    return [] if $allow_empty && @parts && !grep { length } @parts;
    return _normalize_token_option($name, \@parts, $uppercase, 0);
}

sub _normalize_nonnegative_integer {
    my ($label, $value) = @_;
    croak "PAGI::Pages $label must be a non-negative integer"
        unless defined($value) && !ref($value) && $value =~ /\A[0-9]+\z/;
    $value =~ s/\A0+(?=[0-9])//;
    return $value;
}

sub _normalize_retry_after {
    my ($value) = @_;
    return _normalize_nonnegative_integer('retry_after', $value)
        if defined($value) && !ref($value) && $value =~ /\A[0-9]+\z/;
    _validate_field_value('retry_after', $value);
    my $epoch = HTTP::Date::str2time($value);
    croak 'PAGI::Pages retry_after must be delay seconds or a canonical IMF-fixdate'
        unless defined($epoch) && HTTP::Date::time2str($epoch) eq $value;
    return $value;
}

sub _is_http_token {
    my ($value) = @_;
    return defined($value) && !ref($value)
        && $value =~ /\A[!#\$%&'\*\+\-\.\^_\x60\|~0-9A-Za-z]+\z/;
}

sub _has_header {
    my ($headers, $wanted) = @_;
    my $lower = lc $wanted;
    for (my $index = 0; $index < @$headers; $index += 2) {
        return 1 if lc($headers->[$index]) eq $lower;
    }
    return 0;
}

sub _header_values {
    my ($headers, $wanted) = @_;
    my $lower = lc $wanted;
    my @values;
    for (my $index = 0; $index < @$headers; $index += 2) {
        push @values, $headers->[$index + 1]
            if lc($headers->[$index]) eq $lower;
    }
    return @values;
}

sub _replace_header {
    my ($headers, $wanted, $value) = @_;
    my $lower = lc $wanted;
    my (@copy, $inserted);
    for (my $index = 0; $index < @$headers; $index += 2) {
        my ($name, $existing) = @$headers[$index, $index + 1];
        if (lc($name) eq $lower) {
            if (!$inserted) {
                push @copy, $wanted => $value;
                $inserted = 1;
            }
            next;
        }
        push @copy, $name => $existing;
    }
    push @copy, $wanted => $value unless $inserted;
    return \@copy;
}

sub _response_for {
    my ($self, $scope, $page) = @_;
    my $headers = $self->_assembled_headers($scope, $page);
    my $representation = $self->_select_representation($scope, $page);
    my $hook_page = _descriptor_for_hook($page);
    my ($body, $content_type);

    if ($representation eq 'html') {
        my $rendered = $self->render_html($hook_page);
        _reject_future($rendered);
        croak 'render_html must return a Unicode scalar'
            unless defined($rendered) && !ref($rendered);
        $body = encode('UTF-8', $rendered, FB_CROAK);
        $content_type = 'text/html; charset=utf-8';
    }
    elsif ($representation eq 'text') {
        my $rendered = $self->render_text($hook_page);
        _reject_future($rendered);
        croak 'render_text must return a Unicode scalar'
            unless defined($rendered) && !ref($rendered);
        $body = encode('UTF-8', $rendered, FB_CROAK);
        $content_type = 'text/plain; charset=utf-8';
    }
    elsif ($page->{kind} eq 'error') {
        my $rendered = $self->render_problem($hook_page);
        _reject_future($rendered);
        croak 'render_problem must return a hashref'
            unless ref($rendered) eq 'HASH' && !blessed($rendered);
        my %problem = %$rendered;
        $problem{type} = $page->{type};
        $problem{title} = $page->{title};
        $problem{status} = $page->{status};
        $problem{detail} = $page->{detail};
        if (defined $page->{instance}) {
            $problem{instance} = $page->{instance};
        }
        else {
            delete $problem{instance};
        }
        if ($page->{status} == 511 && defined $page->{login_url}) {
            $problem{login} = $page->{login_url};
        }
        elsif ($page->{status} == 511) {
            delete $problem{login};
        }
        $body = eval { JSON::MaybeXS::encode_json(\%problem) };
        croak "PAGI::Pages could not encode problem JSON: $@" if $@;
        $content_type = 'application/problem+json';
    }
    else {
        my $rendered = $self->render_json($hook_page);
        _reject_future($rendered);
        croak 'render_json must return a hashref'
            unless ref($rendered) eq 'HASH' && !blessed($rendered);
        my %json = %$rendered;
        if ($page->{kind} eq 'redirect') {
            $json{status} = $page->{status};
            $json{location} = $page->{location};
        }
        $body = eval { JSON::MaybeXS::encode_json(\%json) };
        croak "PAGI::Pages could not encode JSON: $@" if $@;
        $content_type = 'application/json';
    }

    my $response = PAGI::Response->new($scope);
    $response->status($page->{status});
    my @headers = @$headers;
    while (@headers) {
        my ($name, $value) = splice(@headers, 0, 2);
        $response->header($name, $value);
    }
    $response->headers->set('Content-Type', $content_type);
    $response->send_raw($body);
    return $response;
}

sub _assembled_headers {
    my ($self, $scope, $page) = @_;
    my @headers = @{$page->{headers} || []};

    if ($page->{upgrade_connection}) {
        my $no_body = sub {
            return Future->fail('metadata-only Request cannot consume a body');
        };
        my $version = PAGI::Request->new($scope, $no_body)->http_version;
        croak 'PAGI::Pages status 426 Upgrade requires HTTP/1.1'
            unless defined($version) && !ref($version) && $version eq '1.1';
        # No Connection header: connection-level headers belong to the
        # server, and the PAGI spec's Upgrade companion rule has the server
        # supply the RFC 9110 'Connection: upgrade' pair itself.
    }

    push @headers, 'Cache-Control' => $page->{cache_control}
        if defined $page->{cache_control};
    push @headers, Location => $page->{location}
        if $page->{kind} eq 'redirect';
    return _merge_vary_accept(\@headers)
        if $self->_effective_as($page) eq 'auto';
    return \@headers;
}

sub _descriptor_for_hook {
    my ($page) = @_;
    my %copy = %$page;
    $copy{headers} = [@{$page->{headers}}] if ref($page->{headers}) eq 'ARRAY';
    $copy{extensions} = {%{$page->{extensions}}}
        if ref($page->{extensions}) eq 'HASH';
    return \%copy;
}

sub _effective_as {
    my ($self, $page) = @_;
    return defined($page->{as}) ? $page->{as} : $self->{as};
}

sub _select_representation {
    my ($self, $scope, $page) = @_;
    my $as = $self->_effective_as($page);
    return $as unless $as eq 'auto';

    my @families = ($self->{default});
    push @families, grep { $_ ne $self->{default} } qw(html json text);

    my $no_body = sub {
        return Future->fail('metadata-only Request cannot consume a body');
    };
    my $request = PAGI::Request->new($scope, $no_body);
    my @accept_values = $request->header_all('accept');
    my $accept = @accept_values ? join(', ', @accept_values) : undef;
    my $problem_rejected = $page->{kind} eq 'error'
        ? _problem_type_explicitly_rejected($accept) : 0;
    my (@supported, %family_for);
    for my $family (@families) {
        my @types;
        if ($family eq 'html') {
            @types = ('text/html');
        }
        elsif ($family eq 'text') {
            @types = ('text/plain');
        }
        elsif ($page->{kind} eq 'error') {
            @types = ('application/problem+json');
            push @types, 'application/json' unless $problem_rejected;
        }
        else {
            @types = ('application/json');
        }
        for my $type (@types) {
            push @supported, $type;
            $family_for{$type} = $family;
        }
    }

    my $matched = PAGI::Request::Negotiate->best_match(\@supported, $accept);
    return defined($matched) ? $family_for{$matched} : $self->{default};
}

sub _problem_type_explicitly_rejected {
    my ($accept) = @_;
    return 0 unless defined($accept) && length($accept);
    for my $entry (PAGI::Request::Negotiate->parse_accept($accept)) {
        return 1
            if $entry->[0] eq 'application/problem+json' && $entry->[1] == 0;
    }
    return 0;
}

sub _merge_vary_accept {
    my ($headers) = @_;
    my (@tokens, %seen);
    for my $value (_header_values($headers, 'Vary')) {
        for my $token (split /,/, $value) {
            $token =~ s/\A\s+//;
            $token =~ s/\s+\z//;
            next unless length $token;
            my $key = lc $token;
            next if $seen{$key}++;
            push @tokens, $token;
        }
    }
    push @tokens, 'Accept' unless $seen{accept};
    return _replace_header($headers, 'Vary', join(', ', @tokens));
}

sub _reject_future {
    my ($value) = @_;
    croak 'renderer must return an immediate value'
        if blessed($value) && $value->isa('Future');
    return;
}

sub render_html {
    my ($self, $page) = @_;
    my $title = _html_escape($page->{title});
    my $detail = _html_escape($page->{detail});
    my $status = _html_escape("$page->{status}");

    my $favicon = $self->favicon_href($page);
    _reject_future($favicon);
    my $favicon_link = '';
    if (defined $favicon) {
        _validate_uri_reference('favicon_href', $favicon);
        $favicon_link = '<link rel="icon" type="image/svg+xml" href="'
            . _html_escape($favicon) . '">' . "\n";
    }

    my $action = '';
    if ($page->{kind} eq 'welcome') {
        $action = '<p class="action"><a href="' . _html_escape($page->{documentation})
            . '">' . _html_escape($WELCOME_LABEL) . '</a></p>';
    }
    elsif ($page->{kind} eq 'redirect') {
        $action = '<p class="action"><a href="' . _html_escape($page->{location})
            . '">' . _html_escape($page->{location}) . '</a></p>';
    }
    elsif ($page->{status} == 511 && defined $page->{login_url}) {
        $action = '<p class="action"><a href="' . _html_escape($page->{login_url})
            . '">Network login</a></p>';
    }

    return '<!doctype html>' . "\n"
        . '<html lang="en">' . "\n"
        . '<head>' . "\n"
        . '<meta charset="utf-8">' . "\n"
        . '<meta name="viewport" content="width=device-width, initial-scale=1">' . "\n"
        . '<title>' . $status . ' ' . $title . '</title>' . "\n"
        . $favicon_link
        . '<style>'
        . ':root{color-scheme:light dark;font-family:system-ui,-apple-system,sans-serif;}'
        . '*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;'
        . 'padding:2rem;background:#f3f1eb;color:#282b29}'
        . 'main{width:min(42rem,100%);padding:clamp(2rem,7vw,4rem);border-radius:1rem;'
        . 'background:#fff;box-shadow:0 1rem 3rem rgba(30,35,32,.12)}'
        . '.status{font-size:.85rem;font-weight:700;letter-spacing:.12em;text-transform:uppercase;'
        . 'color:#68706a}h1{margin:.5rem 0 1rem;font-size:clamp(2rem,7vw,3.5rem);line-height:1.05}'
        . 'p{font-size:1.05rem;line-height:1.65}.action{margin-top:2rem}a{color:#365e4b}'
        . '@media(prefers-color-scheme:dark){body{background:#202421;color:#eceeea}'
        . 'main{background:#2b302c}.status{color:#b6beb7}a{color:#9fc9ae}}'
        . '</style>' . "\n"
        . '</head>' . "\n"
        . '<body><main><div class="status">' . $status . '</div><h1>' . $title
        . '</h1><p>' . $detail . '</p>' . $action . '</main></body>' . "\n"
        . '</html>' . "\n";
}

sub render_text {
    my ($self, $page) = @_;
    if ($page->{kind} eq 'welcome') {
        return $page->{title} . "\n\n"
            . $page->{detail} . "\n\n"
            . $WELCOME_LABEL . "\n"
            . $page->{documentation} . "\n";
    }
    my $text = $page->{status} . ' ' . $page->{title} . "\n\n"
        . $page->{detail} . "\n";
    if ($page->{kind} eq 'redirect') {
        $text .= "\nLocation:\n" . $page->{location} . "\n";
    }
    if ($page->{status} == 511 && defined $page->{login_url}) {
        $text .= "\nNetwork login:\n" . $page->{login_url} . "\n";
    }
    return $text;
}

sub render_problem {
    my ($self, $page) = @_;
    my %problem = %{$page->{extensions} || {}};
    $problem{type} = $page->{type};
    $problem{title} = $page->{title};
    $problem{status} = $page->{status};
    $problem{detail} = $page->{detail};
    $problem{instance} = $page->{instance} if defined $page->{instance};
    $problem{login} = $page->{login_url}
        if $page->{status} == 511 && defined $page->{login_url};
    return \%problem;
}

sub render_json {
    my ($self, $page) = @_;
    if ($page->{kind} eq 'redirect') {
        return {
            status   => $page->{status},
            location => $page->{location},
            detail   => $page->{detail},
        };
    }
    return {
        title         => $page->{title},
        detail        => $page->{detail},
        documentation => $page->{documentation},
    };
}

sub moved_permanently {
    my $proto = shift;
    return _invoke_named_redirect($proto, 301, @_);
}

sub found {
    my $proto = shift;
    return _invoke_named_redirect($proto, 302, @_);
}

sub see_other {
    my $proto = shift;
    return _invoke_named_redirect($proto, 303, @_);
}

sub temporary_redirect {
    my $proto = shift;
    return _invoke_named_redirect($proto, 307, @_);
}

sub permanent_redirect {
    my $proto = shift;
    return _invoke_named_redirect($proto, 308, @_);
}

sub favicon_href {
    my ($self, $page) = @_;
    my $status = 0 + $page->{status};
    my $string = "$status";
    my $family = substr($string, 0, 1);
    my $tail = substr($string, 1, 2);
    my $color = $FAVICON_COLOR{$family};
    my $svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"'
        . ' role="img" aria-label="HTTP status ' . $string . '">'
        . '<rect width="64" height="64" rx="12" fill="' . $color . '"/>'
        . '<text x="8" y="47" fill="#faf8f1" font-family="system-ui,sans-serif"'
        . ' font-size="43" font-weight="700">' . $family . '</text>'
        . '<text x="35" y="44" fill="#faf8f1" font-family="system-ui,sans-serif"'
        . ' font-size="20" font-weight="700">' . $tail . '</text></svg>';
    $svg =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge;
    return 'data:image/svg+xml,' . $svg;
}

sub _html_escape {
    my ($value) = @_;
    $value = '' unless defined $value;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    $value =~ s/'/&#39;/g;
    return $value;
}

for my $method (@{PAGI::Pages::_Catalog->_named_methods}) {
    my $status = PAGI::Pages::_Catalog->_code_for_method($method);
    no strict 'refs';
    *{__PACKAGE__ . '::' . $method} = sub {
        my $proto = shift;
        return _invoke_named($proto, $status, @_);
    };
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Pages - Negotiated conventional HTTP response factory

=head1 SYNOPSIS

    use PAGI::Pages;

    # A Context or HTTP scope constructs an ordinary, unsent Response.
    my $response = PAGI::Pages->not_found($context);
    my $response = PAGI::Pages->not_found($scope);

    # Without a request source, the same call compiles a plain coderef.
    my $endpoint = PAGI::Pages->not_found(
        detail => 'That page does not exist.',
    );

    my $response = $endpoint->($context);       # Context handler
    my $response = $endpoint->($scope);         # still unsent
    await $endpoint->($scope, $receive, $send); # native HTTP PAGI app

=head1 DESCRIPTION

C<PAGI::Pages> constructs conventional welcome, redirect, and HTTP error
responses. It centralizes safe stock copy, representation negotiation,
UTF-8 encoding, problem details, cache policy, redirect construction, and
status-specific fields. Every immediate call returns a fresh
L<PAGI::Response>; Pages is not a Router, middleware, template system, or
second response type.

The fixed welcome page says:

    Welcome to PAGI

    PAGI is a spiritual successor to PSGI for asynchronous Perl applications. It
    connects servers, frameworks, and applications across HTTP, WebSocket, and
    Server-Sent Events.

    Read the PAGI documentation →
    https://metacpan.org/pod/PAGI

HTML renders the final label as a link. Text includes the label and URL.
Welcome and redirects use ordinary JSON; errors use RFC 9457 problem JSON.

=head1 CONSTRUCTION

    my $pages = PAGI::Pages->new(
        as      => 'auto', # auto, html, json, or text
        default => 'html', # html, json, or text
    );

C<as> defaults to C<auto>. C<default> defaults to C<html> and is used only by
automatic negotiation. Unknown options and invalid values croak. Instances
contain only immutable, request-independent policy. A class call creates a
fresh default instance of that class; there is no singleton or shared request
state.

=head1 RESPONSE AND ENDPOINT OWNERSHIP

A C<PAGI::Context::HTTP> or an unblessed scope whose explicit C<type> is
C<http> is a request source. It constructs but does not send a response:

    my $response = PAGI::Pages->not_found($scope);
    $response->headers->set('X-Request-ID' => $request_id);
    await $response->respond($send);

The scope-only form is deliberately unsent so raw callers can inspect or
modify the value before the one wire operation. A normal Router Context
handler instead returns the value; the Router adapter owns the send step:

    async sub missing {
        my ($context) = @_;
        return PAGI::Pages->not_found($context);
    }

Do not call C<respond> inside a normal Context route. Use an explicit C<raw>
route when the handler must own C<$receive>, C<$send>, and protocol events.

Without a request source, a page call returns a plain unblessed coderef. It
accepts C<($context, @ignored_callback_metadata)>, C<($scope)>, or the native
HTTP triplet C<($scope, $receive, $send)>. Only the triplet sends. Other
invocation shapes and non-HTTP scopes croak before response construction.

=head1 COMPLETE COMPOSITION FORMS

The following forms are complete at the boundary they demonstrate. Examples
that deploy a server root use L<PAGI::Compose> so lifespan and final HEAD wire
handling have an owner.

=head2 1. Class-style one-off Response from Context

    use PAGI::Compose qw(compose);
    use PAGI::Pages;
    use PAGI::Routing qw(route);

    my $app = compose(routes => [
        route('/missing' => sub {
            my ($context) = @_;
            return PAGI::Pages->not_found($context);
        }),
    ])->to_app;

=head2 2. Welcome endpoint in a small runnable demo

    use PAGI::Compose qw(compose);
    use PAGI::Pages;
    use PAGI::Routing qw(route);

    my $app = compose(routes => [
        route('/' => PAGI::Pages->welcome),
    ])->to_app;

=head2 3. Configured instance and presentation subclass

    package MyApp::Pages;
    use parent 'PAGI::Pages';

    sub render_text {
        my ($self, $page) = @_;
        return "My service: $page->{status} $page->{title}\n";
    }

    sub favicon_href { return '/assets/status.svg' }

    package main;
    use PAGI::Compose qw(compose);
    use PAGI::Routing qw(route);

    my $pages = MyApp::Pages->new(as => 'text', default => 'text');
    my $app = compose(routes => [
        route('/missing' => $pages->not_found),
    ])->to_app;

=head2 4. Returning a Response from an async Context handler

    use Future::AsyncAwait;
    use PAGI::Compose qw(compose);
    use PAGI::Pages;
    use PAGI::Routing qw(route);

    async sub lookup_item { return undef }

    my $app = compose(routes => [
        route('/items/{id}' => async sub {
            my ($context) = @_;
            my $item = await lookup_item($context->path_param('id'));
            return PAGI::Pages->not_found($context) unless $item;
            return $context->json($item);
        }),
    ])->to_app;

=head2 5. Constructing, modifying, and explicitly sending in raw PAGI

    use Future;
    use Future::AsyncAwait;
    use PAGI::Compose qw(compose);
    use PAGI::Pages;

    sub make_request_id { return 'example-request-id' }

    my $http = async sub {
        my ($scope, $receive, $send) = @_;
        my $response = PAGI::Pages->not_found($scope, as => 'text');
        $response->header('X-Request-ID' => make_request_id());
        await Future->wrap($response->respond($send));
    };

    my $app = compose(app => $http)->to_app;

=head2 6. Deferred endpoint in Route

    use PAGI::Compose qw(compose);
    use PAGI::Pages;
    use PAGI::Routing qw(route);

    my $app = compose(routes => [
        route('/old' => PAGI::Pages->permanent_redirect('/new')),
    ])->to_app;

C<route> is an exact, method-aware routing leaf. C</old/child> does not reach
this endpoint, and normal route diagnostics still apply.

=head2 7. Deferred endpoint in Mount

    use PAGI::Compose qw(compose);
    use PAGI::Pages;
    use PAGI::Routing qw(mount);

    my $app = compose(routes => [
        mount('/gone', app => PAGI::Pages->gone),
    ])->to_app;

C<mount> is an opaque prefix owner. It transfers C</gone> and the complete
C</gone/...> subtree to the terminal Pages app; every HTTP method reaches it.
A mounted Pages endpoint ignores the remaining child path. Route and Mount are
therefore not interchangeable selection mechanisms.

=head2 8. Deferred endpoint as the Compose target

    use PAGI::Compose qw(compose);
    use PAGI::Pages;

    my $app = compose(
        app => PAGI::Pages->service_unavailable(retry_after => 300),
    )->to_app;

=head2 9. Direct deferred-endpoint HTTP triplet

    use Future;
    use Future::AsyncAwait;
    use PAGI::Pages;

    my $endpoint = PAGI::Pages->not_found(as => 'text');
    my $embedded_http = async sub {
        my ($scope, $receive, $send) = @_;
        die 'HTTP embedding only' unless ($scope->{type} // '') eq 'http';
        await Future->wrap($endpoint->($scope, $receive, $send));
    };

This is an HTTP-only embedding, not a complete server root: the endpoint
rejects lifespan, WebSocket, SSE, and extension scopes and does not provide a
final deployment HEAD boundary. Invoked directly for HEAD, it sends the full
representation body; the embedding application must supply wire suppression.

=head2 10. The same endpoint deployed through Compose

    use PAGI::Compose qw(compose);
    use PAGI::Pages;

    my $endpoint = PAGI::Pages->not_found;
    my $app = compose(app => $endpoint)->to_app;

Compose consumes root lifespan and places the final HEAD wire boundary outside
Pages. Pages still constructs the full GET-equivalent representation for HEAD;
Compose preserves its status and headers and suppresses the final wire body.

=head2 11. Router HTTP default and ErrorHandler endpoints

    use PAGI::Compose qw(compose);
    use PAGI::Pages;
    use PAGI::Routing qw(router route middleware);

    sub home {
        my ($context) = @_;
        return $context->text('Home');
    }

    my $routing = router(
        routes       => [route('/' => \&home)],
        http_default => PAGI::Pages->not_found,
    );
    my $app = compose(
        app => $routing,
        middleware => [
            middleware('ErrorHandler',
                handler => PAGI::Pages->internal_server_error),
        ],
    )->to_app;

The HTTP default handles only Router NONE. The ErrorHandler endpoint handles a
thrown application error. Pages ignores trailing callback metadata; use a
wrapper when that metadata must choose copy or extensions.

=head2 12. Router-owned MethodNotAllowed union

    use PAGI::Compose qw(compose);
    use PAGI::Pages;
    use PAGI::Routing qw(router route);

    sub items {
        my ($context) = @_;
        return $context->text('Items');
    }

    my $routing = router(routes => [
        route('/items' => \&items, methods => ['GET', 'POST']),
    ]);
    my $app = compose(app => $routing)->to_app;

    # POST is accepted; PUT receives 405 with Allow: GET, HEAD, POST.

=head2 13. HTML, JSON/problem JSON, and text negotiation

    use PAGI::Compose qw(compose);
    use PAGI::Pages;
    use PAGI::Routing qw(route);

    my $app = compose(routes => [
        route('/missing' => PAGI::Pages->not_found),
    ])->to_app;

    # curl -H 'Accept: text/html'                http://localhost:5000/missing
    # curl -H 'Accept: application/problem+json' http://localhost:5000/missing
    # curl -H 'Accept: application/json'         http://localhost:5000/missing
    # curl -H 'Accept: text/plain'                http://localhost:5000/missing

Welcome and redirects instead emit ordinary C<application/json> when
C<application/json> is selected. C<application/problem+json> alone does not
select JSON for those non-problem documents.

=head2 14. Fixed representation and automatic fallback

    use PAGI::Compose qw(compose);
    use PAGI::Pages;
    use PAGI::Routing qw(route);

    my $fixed_pages = PAGI::Pages->new(as => 'json');
    my $auto_pages = PAGI::Pages->new(as => 'auto', default => 'text');
    my $app = compose(routes => [
        route('/fixed' => $fixed_pages->not_found),
        route('/auto'  => $auto_pages->not_found),
    ])->to_app;

C</fixed> ignores Accept and omits C<Vary: Accept>. C</auto> negotiates and
merges C<Accept> into C<Vary>. Missing Accept, C<*/*>, equal-quality default
ties, and total rejection use the configured default. Total rejection does
not recursively create a 406.

=head2 15. Custom RFC 9457 problem

    use PAGI::Compose qw(compose);
    use PAGI::Pages;
    use PAGI::Routing qw(route);

    my $app = compose(routes => [
        route('/upstream' => PAGI::Pages->status(
            599,
            type       => 'https://example.com/problems/upstream-timeout',
            title      => 'Upstream Connection Timeout',
            detail     => 'The reporting gateway could not connect upstream.',
            instance   => '/requests/abc123',
            extensions => { upstream => 'reports' },
        )),
    ])->to_app;

Unknown 400-599 statuses require C<type>, C<title>, and C<detail>. The type
must be an absolute URI other than C<about:blank>. Registered statuses use
C<about:blank> and their registered title unless a custom C<type> and C<title>
are supplied together. C<instance> is never inferred. Problem extensions are
top-level and may not replace C<type>, C<title>, C<status>, C<detail>, or
C<instance>.

=head2 16. Mandatory and status-specific fields

    use PAGI::Compose qw(compose);
    use PAGI::Pages;
    use PAGI::Routing qw(route);

    my $app = compose(routes => [
        route('/login' => PAGI::Pages->unauthorized(
            challenge => 'Bearer realm="api"')),
        route('/proxy' => PAGI::Pages->proxy_authentication_required(
            challenge => 'Basic realm="proxy"')),
        route('/methods' => PAGI::Pages->method_not_allowed(
            allow => [qw(GET HEAD)])),
        route('/upgrade' => PAGI::Pages->upgrade_required(
            upgrade => 'h2c')),
        route('/range' => PAGI::Pages->range_not_satisfiable(
            length => 1234)),
        route('/busy' => PAGI::Pages->too_many_requests(
            retry_after => 30)),
        route('/blocked' => PAGI::Pages->unavailable_for_legal_reasons(
            blocked_by => 'https://example.com/policy')),
        route('/network-login' => PAGI::Pages->network_authentication_required(
            login_url => '/network-login-form')),
    ])->to_app;

The emitted mappings are C<challenge> to C<WWW-Authenticate> for 401 or
C<Proxy-Authenticate> for 407, C<allow> to normalized C<Allow> for 405, and
C<upgrade> to C<Upgrade> for the HTTP/1.1-only 426 (connection-level headers
belong to the server: a PAGI server supplies the RFC 9110
C<Connection: upgrade> companion itself).
Those four inputs are mandatory. C<length> emits
C<Content-Range: bytes */N>; C<retry_after> applies to 413, 429, 503, and
redirects; C<blocked_by> emits a C<blocked-by> Link; C<login_url> becomes the
511 representation link and problem C<login> extension.

407 describes authentication with an intermediary proxy. 511 is intended for
network-interception or captive-portal responses. Neither is an ordinary
origin application's authentication error; origins normally use 401/403.

=head2 17. Redirect query preservation before fragments

    use PAGI::Compose qw(compose);
    use PAGI::Pages;
    use PAGI::Routing qw(route);

    my $app = compose(routes => [
        route('/find' => PAGI::Pages->redirect(
            '/search?sort=date#results',
            status         => 308,
            preserve_query => 1,
        )),
    ])->to_app;

For an incoming C<q=perl>, both Location and the body use
C</search?sort=date&q=perl#results>. Pages appends the raw query without
decoding or re-encoding it. C<preserve_query> defaults to false.

=head2 18. Safe response modification before send

    use Future::AsyncAwait;
    use PAGI::Compose qw(compose);
    use PAGI::Pages;

    sub make_request_id { return 'example-request-id' }

    my $http = async sub {
        my ($scope, $receive, $send) = @_;
        my $response = PAGI::Pages->not_found($scope);
        $response->headers->set('X-Request-ID' => make_request_id());
        await $response->respond($send);
    };

    my $app = compose(app => $http)->to_app;

This is the documented low-level escape hatch. Pages does not revalidate a
Response after construction, so callers that change status, owned fields, or
mandatory fields own the resulting protocol correctness.

=head2 19. Stock, same-origin, and omitted favicons

    package MyApp::AssetPages;
    use parent 'PAGI::Pages';
    sub favicon_href { return '/assets/status.svg' }

    package MyApp::StrictCSPPages;
    use parent 'PAGI::Pages';
    sub favicon_href { return undef }

    package main;
    use PAGI::Compose qw(compose);
    use PAGI::Pages;
    use PAGI::Routing qw(route);

    my $app = compose(routes => [
        route('/stock'  => PAGI::Pages->not_found),
        route('/asset'  => MyApp::AssetPages->not_found),
        route('/strict' => MyApp::StrictCSPPages->not_found),
    ])->to_app;

Stock HTML embeds a percent-encoded SVG data URI containing the exact status,
so it causes no fallback C</favicon.ico> request. A same-origin hook can retain
the stock document under a stricter asset policy. Returning C<undef> omits the
link for Content Security Policies that disallow C<data:> images. A full
C<render_html> override owns the complete document and whether it calls
C<favicon_href>.

=head1 ERROR AND REDIRECT METHODS

C<status($request, $code, %options)> is the general 400-599 error constructor.
The named error methods are ordinary installed methods, not C<AUTOLOAD>
fallbacks:

    400 bad_request                         401 unauthorized
    402 payment_required                    403 forbidden
    404 not_found                           405 method_not_allowed
    406 not_acceptable                      407 proxy_authentication_required
    408 request_timeout                     409 conflict
    410 gone                                411 length_required
    412 precondition_failed                 413 content_too_large
    414 uri_too_long                        415 unsupported_media_type
    416 range_not_satisfiable               417 expectation_failed
    421 misdirected_request                 422 unprocessable_content
    423 locked                              424 failed_dependency
    425 too_early                           426 upgrade_required
    428 precondition_required               429 too_many_requests
    431 request_header_fields_too_large     451 unavailable_for_legal_reasons
    500 internal_server_error               501 not_implemented
    502 bad_gateway                         503 service_unavailable
    504 gateway_timeout                     505 http_version_not_supported
    506 variant_also_negotiates             507 insufficient_storage
    508 loop_detected                       511 network_authentication_required

This checked-in catalog was compared with the
L<IANA HTTP Status Code Registry|https://www.iana.org/assignments/http-status-codes/http-status-codes.xhtml>
on 2026-08-14. IANA lists 418 as unused and 510 as obsoleted, so neither has a
named helper. Use the strict custom C<status> form for a deliberate private or
otherwise unregistered code. The catalog is never fetched at runtime.

Redirects accept only 301, 302, 303, 307, and 308. C<redirect> takes a
C<status> option; the corresponding named methods are C<moved_permanently>,
C<found>, C<see_other>, C<temporary_redirect>, and C<permanent_redirect>.
Named redirect methods reject a conflicting C<status> option.

=head1 OPTIONS, FIELDS, AND CACHE POLICY

Welcome accepts C<as>, C<headers>, and C<cache_control>. Errors additionally
accept C<detail>, C<type>, C<title>, C<instance>, C<extensions>, and the
status-specific semantic options shown above. Redirects accept C<as>,
C<status> on the general method, C<detail>, C<headers>, C<cache_control>,
C<preserve_query>, and C<retry_after>.

The C<headers> option is a flat C<[name =E<gt> value, ...]> arrayref. Pages
rejects malformed fields and reserves C<Content-Type>, C<Content-Length>,
C<Transfer-Encoding>, C<Location>, C<Cache-Control>, and C<Connection> for its
own construction. Automatic negotiation merges C<Accept> into an existing
C<Vary> field without duplicate tokens.

Errors default to C<Cache-Control: no-store>. Callers may explicitly replace
that default except for 428, 429, 431, and 511, whose defining RFCs require
non-storage. Welcome and redirects add no cache field by default.

=head1 CONTENT NEGOTIATION

Automatic negotiation offers HTML, JSON, and text. It uses each concrete
type's most-specific effective Accept quality, honors exact C<q=0>
exclusions, and breaks equal-quality ties in configured-default, HTML, JSON,
then text order. A fixed C<as> ignores Accept. Stock English output does not
negotiate C<Accept-Language>.

=head1 SUBCLASSING AND SYNCHRONOUS WORK

Presentation subclasses may override:

    render_html($descriptor)     # Unicode scalar
    render_text($descriptor)     # Unicode scalar
    render_problem($descriptor)  # hashref for RFC 9457 errors
    render_json($descriptor)     # hashref for welcome and redirects
    favicon_href($descriptor)    # URI-reference scalar or undef

Hooks are synchronous and receive a fresh request-local descriptor. A Future
or invalid return shape is rejected before any send. Pages retains authority
over the wire status, Content-Type, Content-Length, Location, cache policy,
mandatory fields, negotiation, Vary, and the agreement between an RFC 9457
C<status> member and the HTTP status.

Stock construction is bounded in-memory work: it inspects the existing HTTP
scope, negotiates three representation families, validates short scalars and
fields, escapes fixed page copy, encodes one small document, and constructs a
Response. It performs no filesystem or network I/O, subprocess work, dynamic
renderer loading, template discovery, or runtime catalog lookup. Fetch async
application data before calling Pages; only C<respond($send)> is asynchronous.

=head1 SEE ALSO

L<PAGI::Response> for literal low-level response construction and sending,
L<PAGI::Routing> for exact routes and opaque mounts, L<PAGI::Compose> for the
deployed lifespan/HEAD/error boundary, L<PAGI::Middleware::ErrorHandler>,
L<PAGI::Tools::Tutorial>, L<PAGI::Tools::Cookbook>

=cut
