package PAGI::Pages;

use strict;
use warnings;

use Carp qw(croak);
use Exporter qw(import);
use Future;
use HTTP::Date ();
use JSON::MaybeXS ();
use Scalar::Util qw(blessed);

use PAGI::Pages::_Catalog;
use PAGI::Request;
use PAGI::Request::Negotiate;
use PAGI::Response ();
use PAGI::Response::Empty ();
use PAGI::Response::HTML ();
use PAGI::Response::JSON ();
use PAGI::Response::Problem ();
use PAGI::Response::Text ();
use PAGI::Utils::Scope ();

our @EXPORT;
our @EXPORT_OK = (
    qw(welcome_page status_page redirect_page),
    @{PAGI::Pages::_Catalog->_named_page_functions},
);
our %EXPORT_TAGS = (
    common => [qw(
        welcome_page status_page redirect_page not_found_page unauthorized_page
        forbidden_page method_not_allowed_page conflict_page too_many_requests_page
        internal_server_error_page bad_gateway_page service_unavailable_page
    )],
    all => [@EXPORT_OK],
);

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

    return $self->_response_for(_scope_from_source($source), $factory->());
}

sub status {
    my ($proto, @args) = @_;
    my $self = _policy_for($proto);
    my $source = _take_request_source(\@args);
    my $status = shift @args;
    $status = _validated_status($status);
    my $opts = _normalize_options('error', \%ERROR_OPTION, @args);
    my $factory = _error_factory($status, $opts);

    return $self->_response_for(_scope_from_source($source), $factory->());
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

    my $scope = _scope_from_source($source);
    return $self->_response_for($scope, $factory->($scope));
}

sub _invoke_named {
    my ($proto, $status, @args) = @_;
    my $self = _policy_for($proto);
    my $source = _take_request_source(\@args);
    my $opts = _normalize_options('error', \%ERROR_OPTION, @args);
    my $factory = _error_factory($status, $opts);

    return $self->_response_for(_scope_from_source($source), $factory->());
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

    my $scope = _scope_from_source($source);
    return $self->_response_for($scope, $factory->($scope));
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
    croak 'PAGI::Pages requires one explicit Request or HTTP-capable metadata source'
        unless @$args && PAGI::Utils::Scope::is_scope_source($args->[0]);
    my $source = shift @$args;
    if (blessed($source)) {
        croak 'PAGI::Pages source must be a Request, WebSocket, SSE, or unblessed scope'
            unless $source->isa('PAGI::Request')
                || $source->isa('PAGI::WebSocket')
                || $source->isa('PAGI::SSE');
    }
    _scope_from_source($source);
    return $source;
}

sub _scope_from_source {
    my ($source) = @_;
    my $scope = PAGI::Utils::Scope::scope_from_source('PAGI::Pages', $source);

    my $type = $scope->{type};
    croak 'PAGI::Pages scope type is required'
        unless defined($type) && !ref($type) && length($type);
    croak "PAGI::Pages requires HTTP-capable metadata; received '$type'"
        unless $type eq 'http' || $type eq 'websocket' || $type eq 'sse';
    return $scope;
}

sub _http_metadata_scope {
    my ($scope) = @_;
    return $scope if $scope->{type} eq 'http';
    my %metadata = %$scope;
    $metadata{type} = 'http';
    $metadata{method} = 'GET'
        unless defined($metadata{method}) && !ref($metadata{method});
    $metadata{path} = '/'
        unless defined($metadata{path}) && !ref($metadata{path});
    return \%metadata;
}

sub welcome_page { return PAGI::Pages->welcome(@_) }
sub status_page { return PAGI::Pages->status(@_) }
sub redirect_page { return PAGI::Pages->redirect(@_) }

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
    if (PAGI::Response::_status_forbids_body($page->{status})) {
        return PAGI::Response::Empty->new(
            status => $page->{status}, headers => $headers,
        );
    }

    my $representation = $self->_select_representation($scope, $page);
    my $hook_page = _descriptor_for_hook($page);

    if ($representation eq 'html') {
        my $rendered = $self->render_html($hook_page);
        _reject_future($rendered);
        croak 'render_html must return a Unicode scalar'
            unless defined($rendered) && !ref($rendered);
        return PAGI::Response::HTML->new(
            $rendered, status => $page->{status}, headers => $headers,
        );
    }
    if ($representation eq 'text') {
        my $rendered = $self->render_text($hook_page);
        _reject_future($rendered);
        croak 'render_text must return a Unicode scalar'
            unless defined($rendered) && !ref($rendered);
        return PAGI::Response::Text->new(
            $rendered, status => $page->{status}, headers => $headers,
        );
    }
    if ($page->{kind} eq 'error') {
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
        return PAGI::Response::Problem->new(
            \%problem, status => $page->{status}, headers => $headers,
        );
    }

    my $rendered = $self->render_json($hook_page);
    _reject_future($rendered);
    croak 'render_json must return a hashref'
        unless ref($rendered) eq 'HASH' && !blessed($rendered);
    my %json = %$rendered;
    if ($page->{kind} eq 'redirect') {
        $json{status} = $page->{status};
        $json{location} = $page->{location};
    }
    return PAGI::Response::JSON->new(
        \%json, status => $page->{status}, headers => $headers,
    );
}

sub _assembled_headers {
    my ($self, $scope, $page) = @_;
    my @headers = @{$page->{headers} || []};

    if ($page->{upgrade_connection}) {
        my $no_body = sub {
            return Future->fail('metadata-only Request cannot consume a body');
        };
        my $version = PAGI::Request->new(
            _http_metadata_scope($scope), $no_body,
        )->http_version;
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
    my $request = PAGI::Request->new(
        _http_metadata_scope($scope), $no_body,
    );
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
    my $function = $method . '_page';
    no strict 'refs';
    *{__PACKAGE__ . '::' . $method} = sub {
        my $proto = shift;
        return _invoke_named($proto, $status, @_);
    };
    *{__PACKAGE__ . '::' . $function} = sub {
        return PAGI::Pages->$method(@_);
    };
}

1;

__END__
=encoding UTF-8

=head1 NAME

PAGI::Pages - negotiated conventional HTTP response policy

=head1 SYNOPSIS

    use PAGI::Pages qw(
        welcome_page not_found_page gone_page redirect_page
    );
    use PAGI::Routing qw(route mount request_app);

    my @routes = (
        route('/welcome' => \&welcome_page),
        route('/missing' => \&not_found_page),
        route('/old' => sub {
            my ($request) = @_;
            return redirect_page($request, '/new', status => 308);
        }),
        mount('/gone', app => request_app(\&gone_page)),
    );

Class and configured-instance methods take the same explicit metadata source:

    my $response = PAGI::Pages->not_found(
        $request,
        detail => 'That record is not available.',
    );

    my $pages = MyApp::Pages->new(as => 'auto', default => 'text');
    my $response = $pages->not_found($request);

A raw application constructs and emits in separate operations:

    my $raw = async sub {
        my ($scope, $receive, $send) = @_;
        my $response = PAGI::Pages->not_found($scope, as => 'text');
        $response->header('X-Request-ID' => request_id());
        await Future->wrap(
            $response->respond($scope, $receive, $send),
        );
    };

=head1 DESCRIPTION

C<PAGI::Pages> owns bounded synchronous policy for conventional welcome,
redirect, and HTTP error responses. It selects a representation, applies the
checked-in status catalog and status-specific fields, calls presentation hooks,
and immediately returns one unsent concrete L<PAGI::Response>.

Pages never sends events. It is neither a native PAGI application nor an
arity-overloaded endpoint factory. A no-source call croaks. Native placement
uses L<PAGI::Routing/request_app>; a real raw closure calls the Response
C<respond($scope, $receive, $send)> method explicitly.

The returned class identifies the selected representation:

=over 4

=item * L<PAGI::Response::HTML> for HTML

=item * L<PAGI::Response::Text> for text

=item * L<PAGI::Response::JSON> for welcome or redirect JSON

=item * L<PAGI::Response::Problem> for RFC 9457 error JSON

=item * L<PAGI::Response::Empty> when a policy descriptor forbids a body

=back

The concrete class owns encoding and Content-Length. Pages does not duplicate
either operation.

=head1 CONSTRUCTION

    my $pages = PAGI::Pages->new(
        as      => 'auto', # auto, html, json, or text
        default => 'html', # html, json, or text
    );

C<as> defaults to C<auto>. C<default> defaults to C<html> and is used only by
automatic negotiation. Instances contain request-independent policy and can be
reused concurrently. A class method call constructs a fresh default policy
instance of the invoked class.

=head1 METADATA SOURCES

Every page method and exported function requires exactly one explicit leading
metadata source. Accepted sources are a L<PAGI::Request>, L<PAGI::WebSocket>,
L<PAGI::SSE>, or an unblessed C<http>, C<websocket>, or C<sse> scope hashref.

WebSocket and SSE sources provide pre-start HTTP handshake metadata only.
Pages returns an HTTP Response and does not accept a WebSocket, start SSE, or
emit a protocol event. Lifespan and unknown scope types are rejected.

=head1 EXPORTED REQUEST HANDLERS

Nothing exports by default. Function names make their result explicit:

    use PAGI::Pages qw(
        welcome_page status_page redirect_page not_found_page
    );

C<welcome_page>, C<status_page>, and C<redirect_page> are the generic
functions. Every checked-in named status method has a corresponding
C<*_page> function. Each function delegates to the matching base-class method
with exactly the same source and options.

The C<:common> tag exports exactly:

    welcome_page status_page redirect_page
    not_found_page unauthorized_page forbidden_page
    method_not_allowed_page conflict_page too_many_requests_page
    internal_server_error_page bad_gateway_page service_unavailable_page

The C<:all> tag exports the three generic functions and every catalog-derived
C<*_page> function. Neither tag includes named redirect shortcuts.

Exported functions are ordinary one-Request handlers and can be passed
directly to C<route>. They are not native three-argument applications:

    route('/missing' => \&not_found_page);
    mount('/missing', app => request_app(\&not_found_page));

=head1 METHODS

=head2 welcome

    my $response = PAGI::Pages->welcome($source, %options);

Builds the stock Welcome page. It accepts C<as>, C<headers>, and
C<cache_control>.

=head2 status

    my $response = PAGI::Pages->status($source, $code, %options);

Builds an error response for an integer status from 400 through 599.
Registered codes use the checked-in catalog. An unregistered code requires
C<type>, C<title>, and C<detail>.

=head2 named error methods

Every catalog entry is installed as an ordinary method, including
C<bad_request>, C<unauthorized>, C<forbidden>, C<not_found>,
C<method_not_allowed>, C<conflict>, C<too_many_requests>,
C<internal_server_error>, C<bad_gateway>, and C<service_unavailable>.
The complete method set follows the checked-in IANA-derived catalog; 418 is
unused and 510 obsolete, so neither has a named method.

=head2 redirect

    my $response = PAGI::Pages->redirect(
        $source,
        '/new',
        status         => 308,
        preserve_query => 1,
    );

Redirect status is one of 301, 302, 303, 307, or 308. Named methods
C<moved_permanently>, C<found>, C<see_other>, C<temporary_redirect>, and
C<permanent_redirect> fix the corresponding status and reject a C<status>
option.

C<preserve_query> appends the original raw query before the first fragment
without decoding or re-encoding it. The target, query, Location field, and
rendered body are validated and use one final URI-reference.

=head1 CONTENT NEGOTIATION

Automatic negotiation offers HTML, JSON, and text. Errors use
C<application/problem+json>; welcome and redirects use ordinary
C<application/json>. Repeated Accept fields are combined in wire order.
Automatic selection merges C<Accept> into C<Vary> case-insensitively; a fixed
C<as> ignores Accept and does not add Vary. Missing Accept, C<*/*>, equal
quality, and total rejection use the configured default.

=head1 PROBLEM DETAILS AND STATUS FIELDS

Error JSON is RFC 9457 problem JSON. Pages owns C<type>, C<title>, C<status>,
C<detail>, and optional C<instance>. Extensions are copied and cannot replace
those members. A 511 C<login_url> also owns the C<login> member.

Status-specific options include:

=over 4

=item * C<challenge> for 401 and 407

=item * C<allow> for 405

=item * C<length> for 416

=item * C<upgrade> for HTTP/1.1 status 426

=item * C<retry_after> for 413, 429, 503, and redirects

=item * C<blocked_by> for 451

=item * C<login_url> for 511

=back

The mandatory authentication, Allow, and Upgrade fields may instead be
supplied as validated raw headers. Repeated authentication challenges remain
separate field lines. Pages reserves Content-Type, Content-Length,
Transfer-Encoding, Location, Cache-Control, and Connection.

Errors default to C<Cache-Control: no-store>. Statuses 428, 429, 431, and 511
cannot weaken that policy. Welcome and redirects add no cache field by default.

=head1 PRESENTATION HOOKS

Subclasses may override:

    render_html($descriptor)     # Unicode scalar
    render_text($descriptor)     # Unicode scalar
    render_problem($descriptor)  # unblessed hashref
    render_json($descriptor)     # unblessed hashref
    favicon_href($descriptor)    # URI-reference scalar or undef

Hooks receive fresh request-local descriptors. Futures and invalid return
shapes croak synchronously before a Response is returned. Pages reasserts
authoritative problem members, redirect status and location, headers, cache
policy, and representation metadata after hooks run.

Stock HTML escapes dynamic values and embeds an exact-status SVG favicon.
C<favicon_href> may return a same-origin URI or C<undef>. A complete
C<render_html> override owns the entire document and favicon inclusion.

=head1 RESPONSE OWNERSHIP

A Request handler returns the Response and lets Routing emit it:

    sub missing {
        my ($request) = @_;
        my $response = PAGI::Pages->not_found($request, as => 'text');
        $response->header('X-Request-ID' => request_id());
        return $response;
    }

Only code that already owns the native triplet emits directly:

    await Future->wrap(
        $response->respond($scope, $receive, $send),
    );

Pages performs no filesystem or network I/O, dynamic catalog lookup, template
discovery, or transport adaptation. Fetch asynchronous application data before
calling Pages.

=head1 SEE ALSO

L<PAGI::Response>, L<PAGI::Routing>, L<PAGI::Request>,
L<PAGI::WebSocket>, L<PAGI::SSE>

=cut
