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
use PAGI::Pages::Application ();
use PAGI::Request;
use PAGI::Request::Negotiate;
use PAGI::Response ();
use PAGI::Response::Empty ();
use PAGI::Response::HTML ();
use PAGI::Response::JSON ();
use PAGI::Response::Problem ();
use PAGI::Response::Text ();
use PAGI::Utils::Headers qw(merge_vary);

our @EXPORT;
our @EXPORT_OK = (
    qw(welcome status redirect),
    @{PAGI::Pages::_Catalog->_named_methods},
);
our %EXPORT_TAGS = (
    common => [qw(
        welcome not_found unauthorized forbidden method_not_allowed conflict
        too_many_requests internal_server_error bad_gateway service_unavailable
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
    my ($proto, @args) = _factory_invocation(@_);
    my $self = _policy_for($proto);
    my $opts = _normalize_options('welcome', \%WELCOME_OPTION, @args);
    my $factory = sub { return _welcome_descriptor($opts) };

    return _application_for($self, $factory);
}

sub status {
    my ($proto, @args) = _factory_invocation(@_);
    my $self = _policy_for($proto);
    my $status = shift @args;
    $status = _validated_status($status);
    my $opts = _normalize_options('error', \%ERROR_OPTION, @args);
    my $factory = _error_factory($status, $opts);

    return _application_for($self, $factory);
}

sub redirect {
    my ($proto, @args) = _factory_invocation(@_);
    my $self = _policy_for($proto);
    my $target = shift @args;
    my $opts = _normalize_options('redirect', \%REDIRECT_OPTION, @args);
    my $status = exists($opts->{status})
        ? _validated_redirect_status($opts->{status}) : 302;
    my $factory = _redirect_factory($target, $status, $opts);

    return _application_for($self, $factory);
}

sub _invoke_named {
    my ($status, @call) = @_;
    my ($proto, @args) = _factory_invocation(@call);
    my $self = _policy_for($proto);
    my $opts = _normalize_options('error', \%ERROR_OPTION, @args);
    my $factory = _error_factory($status, $opts);

    return _application_for($self, $factory);
}

sub _invoke_named_redirect {
    my ($proto, $status, @args) = @_;
    my $self = _policy_for($proto);
    my $target = shift @args;
    my $opts = _normalize_options('redirect', \%REDIRECT_OPTION, @args);
    croak 'PAGI::Pages named redirect methods do not accept a status option'
        if exists $opts->{status};
    my $factory = _redirect_factory($target, $status, $opts);

    return _application_for($self, $factory);
}

sub _factory_invocation {
    return ('PAGI::Pages', @_)
        unless @_ && _is_pages_invocant($_[0]);
    return @_;
}

sub _is_pages_invocant {
    my ($value) = @_;
    return $value->isa('PAGI::Pages')
        if blessed($value);
    return defined($value) && !ref($value)
        && $value->isa('PAGI::Pages');
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

sub _application_for {
    my ($policy, $descriptor_factory) = @_;
    return PAGI::Pages::Application->new(
        policy             => $policy,
        descriptor_factory => $descriptor_factory,
    );
}

sub _metadata_scope {
    my ($scope) = @_;
    my %metadata = %$scope;
    delete $metadata{'pagi.request.headers'};
    return \%metadata;
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
    return _validate_uri_reference(
        'redirect target',
        PAGI::Response::_location_with_raw_query($target, $query),
    );
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
            _metadata_scope($scope), $no_body,
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
    # Request lazily installs its header cache; keep those writes local while
    # descriptor factories retain the original scope identity.
    my $request = PAGI::Request->new(
        _metadata_scope($scope), $no_body,
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
    return _replace_header($headers, 'Vary', merge_vary(
        [_header_values($headers, 'Vary')], 'Accept',
    ));
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
        return _invoke_named($status, @_);
    };
}

1;

__END__
=encoding UTF-8

=head1 NAME

PAGI::Pages - negotiated conventional HTTP response policy

=head1 SYNOPSIS

    use PAGI::Pages qw(
        welcome not_found gone redirect
    );
    use PAGI::Routing qw(route mount router);

    my @routes = (
        route('/welcome' => welcome()),
        route('/missing' => not_found()),
        route('/old' => sub {
            my ($request) = @_;
            return redirect('/new', status => 308);
        }),
        mount('/gone', app => gone()),
    );

    my $routing = router(
        routes       => \@routes,
        http_default => not_found(detail => 'No matching route'),
    );

Class and configured-instance methods return the same deferred application
shape:

    my $missing = PAGI::Pages->not_found(
        detail => 'That record is not available.',
    );

    my $pages = MyApp::Pages->new(as => 'auto', default => 'text');
    my $configured_missing = $pages->not_found();

A native application delegates through the common application protocol:

    use PAGI::Utils qw(invoke_app);

    my $native = async sub {
        my ($scope, $receive, $send) = @_;
        await invoke_app(
            PAGI::Pages->not_found(
                as => 'text', headers => ['X-Request-ID' => request_id()],
            ),
            $scope, $receive, $send,
        );
    };

As a small automatic-lifespan server root:

    pagi-server -MPAGI::Pages -e 'PAGI::Pages->welcome'

=head1 DESCRIPTION

C<PAGI::Pages> owns bounded synchronous policy for conventional welcome,
redirect, and HTTP error responses. It selects a representation, applies the
checked-in status catalog and status-specific fields, calls presentation hooks,
and constructs one concrete L<PAGI::Response> when its deferred application is
invoked.

Factories accept options only, perform no request I/O, and return a reusable
L<PAGI::Pages::Application> for HTTP, WebSocket, and SSE. Negotiation uses the
later invocation scope. A Request or scope is not a factory argument. The
application constructs a fresh request-local descriptor and concrete Response,
then invokes it through the common application path.

C<ref($response)> during rendering identifies the concrete representation
selected by policy; Pages does not hide it behind a generic mutable Response.

Materialization returns a concrete Response whose class identifies the selected
representation:

=over 4

=item * L<PAGI::Response::HTML> for HTML

=item * L<PAGI::Response::Text> for text

=item * L<PAGI::Response::JSON> for welcome or redirect JSON

=item * L<PAGI::Response::Problem> for RFC 9457 error JSON

=item * L<PAGI::Response::Empty> when a policy descriptor forbids a body

=back

The concrete class owns encoding and Content-Length. Pages does not duplicate
either operation.

=head1 API REFERENCE

=head2 new

    my $pages = PAGI::Pages->new(
        as      => 'auto', # auto, html, json, or text
        default => 'html', # html, json, or text
    );

C<new(%options)> is a class method and returns a reusable, request-independent
policy object. It accepts a flat key/value list with these options:

=over 4

=item * C<as>

C<auto>, C<html>, C<json>, or C<text>; defaults to C<auto>. A factory's
per-call C<as> overrides this value for that application.

=item * C<default>

C<html>, C<json>, or C<text>; defaults to C<html>. It is used only when
C<as> is C<auto> and negotiation has no preferred supported representation.
C<default> is constructor-only and is not accepted by factories.

=back

Unknown options, odd option lists, and invalid values croak. Instances can be
reused concurrently. A class factory call constructs a fresh default policy
instance of the invoked class, so a subclass class call retains that subclass's
hooks. A configured-instance call retains the exact object and its policy.

=head2 APPLICATION INVOCATION

Every page method and exported function returns a deferred application. On an
HTTP, WebSocket, or SSE invocation it derives negotiation metadata from the
supplied scope, creates one descriptor and concrete Response, and invokes that
Response. A WebSocket or SSE handler may pass the application directly to
C<deny> or C<decline>; C<response_for> remains available when explicit local
materialization is useful.

Factory C<headers> options are flat response-header arrayrefs. For request
negotiation, Pages builds an isolated metadata view and reads repeated request
fields through L<PAGI::Headers>; it does not reuse or mutate the source scope's
C<pagi.request.headers> cache.

Pages rejects lifespan and unknown scopes before receive, rendering, or send.
Pages does not handle lifespan. At a bare server root,
automatic lifespan mode treats the lifespan exception as a decline and
continues without sending later lifespan events; strict mode rejects startup.
Use L<PAGI::Compose> when the root needs lifecycle hooks, root safety, or final
HEAD policy.

=head2 IMPORTS

Nothing exports by default. Import only the source-free factories needed by a
package:

    use PAGI::Pages qw(
        welcome status redirect not_found
    );

C<welcome>, C<status>, and C<redirect> are the generic functions. Every named
error method documented below has a matching function. An imported function
uses a fresh default C<PAGI::Pages> policy; it does not capture a configured
instance or a caller package's subclass.

The C<:common> tag exports exactly:

    welcome
    not_found unauthorized forbidden method_not_allowed conflict
    too_many_requests internal_server_error bad_gateway service_unavailable

C<:common> deliberately excludes collision-prone C<status> and C<redirect>;
import those individually when wanted. C<:all> includes every opt-in factory.
An explicit import still can replace a same-named local function, so qualified
class or configured-instance calls are the collision-free shared-package form.

The five named redirect helpers are methods only. C<moved_permanently>,
C<found>, C<see_other>, C<temporary_redirect>, and C<permanent_redirect> are
not in C<@EXPORT_OK> or C<:all>.

Exported functions return app objects that can be placed directly:

    route('/missing' => not_found());
    mount('/missing', app => not_found());

=head2 FACTORY REFERENCE

Every factory below immediately returns a deferred
L<PAGI::Pages::Application>. It takes no Request or scope argument. Rendering,
negotiation, and concrete Response construction happen when that application
is invoked. Use L<PAGI::Pages::Application/to_app> to obtain its native
application coderef or L<PAGI::Pages::Application/response_for> to immediately
materialize one concrete Response.

=head3 welcome

    use PAGI::Pages qw(welcome);
    my $page = welcome(%options);
    my $class_page = PAGI::Pages->welcome(%options);
    my $configured_page = $pages->welcome(%options);

Returns a deferred 200 Welcome application. C<%options> is a flat key/value
list accepting exactly C<as>, C<headers>, and C<cache_control>; see
L</"WELCOME OPTIONS"> for shapes and defaults. The configured form retains
C<$pages>; a per-call C<as> overrides its policy selection. The stock page is
titled "Welcome to PAGI", describes PAGI's HTTP, WebSocket, and Server-Sent
Events role, and links to L<https://metacpan.org/pod/PAGI>.

=head3 status

    use PAGI::Pages qw(status);
    my $page = status($code, %options);
    my $class_page = PAGI::Pages->status($code, %options);
    my $configured_page = $pages->status($code, %options);

C<$code> is an integer from 400 through 599. The result is a deferred error
application with that status. Registered codes use the same stock title and
detail as their named factory. An unregistered code requires C<type>, C<title>,
and C<detail>. C<%options> accepts the common error options and only the
status-specific options applicable to C<$code>; see L</"ERROR OPTIONS"> and
L</"STATUS-SPECIFIC ERROR OPTIONS">. A custom C<type> is an absolute URI other
than C<about:blank>. Factory-time validation rejects an unsupported code,
missing custom fields, or an option invalid for the selected status.

=head3 redirect

    use PAGI::Pages qw(redirect);
    my $page = redirect($target, %options);
    my $class_page = PAGI::Pages->redirect($target, %options);
    my $configured_page = $pages->redirect($target, %options);

Returns a deferred redirect application. C<$target> is a required ASCII
URI-reference scalar. C<%options> is a flat key/value list accepting exactly
C<as>, C<status>, C<detail>, C<headers>, C<cache_control>, C<preserve_query>,
and C<retry_after>; see L</"REDIRECT OPTIONS">. C<status> defaults to 302 and
must be 301, 302, 303, 307, or 308. The configured form retains C<$pages>; a
per-call C<as> overrides its policy selection.

=head2 NAMED ERROR FACTORIES

Each named error supports the exported, class, and configured-instance forms
shown in its entry. Each returns a deferred application and takes only a flat
option list, never a Request or scope. Unless an entry says otherwise, its
complete option set is C<as>, C<detail>, C<type>, C<title>, C<instance>,
C<extensions>, C<headers>, and C<cache_control>. The stock detail shown is the
default. All errors default to C<type =E<gt> 'about:blank'> and
C<cache_control =E<gt> 'no-store'>; C<instance> is omitted and C<extensions>
is empty. Supplying a custom C<type> and C<title> requires both. See
L</"ERROR OPTIONS"> for value shapes and shared constraints.

=head3 bad_request

    use PAGI::Pages qw(bad_request);
    my $page = bad_request(%options);
    my $class_page = PAGI::Pages->bad_request(%options);
    my $configured_page = $pages->bad_request(%options);

Returns a deferred 400 C<Bad Request> application. The stock detail is
"The server could not understand the request." It accepts the common error
option set and defaults described in L</"ERROR OPTIONS">.

=head3 unauthorized

    use PAGI::Pages qw(unauthorized);
    my $page = unauthorized(challenge => 'Bearer realm="api"', %options);
    my $class_page = PAGI::Pages->unauthorized(challenge => 'Bearer realm="api"', %options);
    my $configured_page = $pages->unauthorized(challenge => 'Bearer realm="api"', %options);

Returns a deferred 401 C<Unauthorized> application. The stock detail is
"Authentication is required to access this resource." In addition to the
common options in L</"ERROR OPTIONS">, it accepts C<challenge>, which is
required unless C<headers> supplies at least one nonempty
C<WWW-Authenticate> field. See L</"STATUS-SPECIFIC ERROR OPTIONS">.

=head3 payment_required

    use PAGI::Pages qw(payment_required);
    my $page = payment_required(%options);
    my $class_page = PAGI::Pages->payment_required(%options);
    my $configured_page = $pages->payment_required(%options);

Returns a deferred 402 C<Payment Required> application. The stock detail is
"Payment is required to access this resource." It accepts the common error
option set and defaults described in L</"ERROR OPTIONS">.

=head3 forbidden

    use PAGI::Pages qw(forbidden);
    my $page = forbidden(%options);
    my $class_page = PAGI::Pages->forbidden(%options);
    my $configured_page = $pages->forbidden(%options);

Returns a deferred 403 C<Forbidden> application. The stock detail is "You do
not have permission to access this resource." It accepts the common error
option set and defaults described in L</"ERROR OPTIONS">.

=head3 not_found

    use PAGI::Pages qw(not_found);
    my $page = not_found(detail => 'No matching record');
    my $class_page = PAGI::Pages->not_found(detail => 'No matching record');

    my $pages = PAGI::Pages->new(as => 'auto', default => 'text');
    my $configured_page = $pages->not_found(detail => 'No matching record');

All three forms return a deferred 404 C<Not Found> application. Options are a
flat key/value list; no Request or scope is a factory argument. The complete
option set is C<as>, C<detail>, C<type>, C<title>, C<instance>, C<extensions>,
C<headers>, and C<cache_control>. The stock detail is "The requested resource
was not found." C<type> defaults to C<about:blank>, C<cache_control> defaults
to C<no-store>, and a custom C<type>/C<title> override must supply both. The
configured form retains C<$pages>; its default representation is text when
automatic negotiation has no preference, and a per-call C<as> overrides the
policy selection. See L</"ERROR OPTIONS"> for complete shapes and constraints.

=head3 method_not_allowed

    use PAGI::Pages qw(method_not_allowed);
    my $page = method_not_allowed(allow => [qw(GET HEAD)], %options);
    my $class_page = PAGI::Pages->method_not_allowed(allow => [qw(GET HEAD)], %options);
    my $configured_page = $pages->method_not_allowed(allow => [qw(GET HEAD)], %options);

Returns a deferred 405 C<Method Not Allowed> application. The stock detail is
"The request method is not allowed for this resource." In addition to the
common options in L</"ERROR OPTIONS">, it accepts C<allow>, which is required
unless C<headers> supplies C<Allow>. See
L</"STATUS-SPECIFIC ERROR OPTIONS">.

=head3 not_acceptable

    use PAGI::Pages qw(not_acceptable);
    my $page = not_acceptable(%options);
    my $class_page = PAGI::Pages->not_acceptable(%options);
    my $configured_page = $pages->not_acceptable(%options);

Returns a deferred 406 C<Not Acceptable> application. The stock detail is
"The requested response representation is not available." It accepts the
common error option set and defaults described in L</"ERROR OPTIONS">.

=head3 proxy_authentication_required

    use PAGI::Pages qw(proxy_authentication_required);
    my $page = proxy_authentication_required(challenge => 'Basic realm="proxy"', %options);
    my $class_page = PAGI::Pages->proxy_authentication_required(
        challenge => 'Basic realm="proxy"', %options,
    );
    my $configured_page = $pages->proxy_authentication_required(
        challenge => 'Basic realm="proxy"', %options,
    );

Returns a deferred 407 C<Proxy Authentication Required> application. The stock
detail is "Proxy authentication is required to access this resource." In
addition to the common options in L</"ERROR OPTIONS">, it accepts
C<challenge>, which is required unless C<headers> supplies at least one
nonempty C<Proxy-Authenticate> field. See
L</"STATUS-SPECIFIC ERROR OPTIONS">.

=head3 request_timeout

    use PAGI::Pages qw(request_timeout);
    my $page = request_timeout(%options);
    my $class_page = PAGI::Pages->request_timeout(%options);
    my $configured_page = $pages->request_timeout(%options);

Returns a deferred 408 C<Request Timeout> application. The stock detail is
"The server timed out waiting for the request." It accepts the common error
option set and defaults described in L</"ERROR OPTIONS">.

=head3 conflict

    use PAGI::Pages qw(conflict);
    my $page = conflict(%options);
    my $class_page = PAGI::Pages->conflict(%options);
    my $configured_page = $pages->conflict(%options);

Returns a deferred 409 C<Conflict> application. The stock detail is "The
request conflicts with the current state of the resource." It accepts the
common error option set and defaults described in L</"ERROR OPTIONS">.

=head3 gone

    use PAGI::Pages qw(gone);
    my $page = gone(%options);
    my $class_page = PAGI::Pages->gone(%options);
    my $configured_page = $pages->gone(%options);

Returns a deferred 410 C<Gone> application. The stock detail is "The requested
resource is no longer available." It accepts the common error option set and
defaults described in L</"ERROR OPTIONS">.

=head3 length_required

    use PAGI::Pages qw(length_required);
    my $page = length_required(%options);
    my $class_page = PAGI::Pages->length_required(%options);
    my $configured_page = $pages->length_required(%options);

Returns a deferred 411 C<Length Required> application. The stock detail is
"The request must include a Content-Length header." It accepts the common
error option set and defaults described in L</"ERROR OPTIONS">.

=head3 precondition_failed

    use PAGI::Pages qw(precondition_failed);
    my $page = precondition_failed(%options);
    my $class_page = PAGI::Pages->precondition_failed(%options);
    my $configured_page = $pages->precondition_failed(%options);

Returns a deferred 412 C<Precondition Failed> application. The stock detail is
"A precondition for this request was not met." It accepts the common error
option set and defaults described in L</"ERROR OPTIONS">.

=head3 content_too_large

    use PAGI::Pages qw(content_too_large);
    my $page = content_too_large(retry_after => 60, %options);
    my $class_page = PAGI::Pages->content_too_large(retry_after => 60, %options);
    my $configured_page = $pages->content_too_large(retry_after => 60, %options);

Returns a deferred 413 C<Content Too Large> application. The stock detail is
"The request content is too large for the server to process." In addition to
the common options in L</"ERROR OPTIONS">, it accepts optional C<retry_after>;
see L</"STATUS-SPECIFIC ERROR OPTIONS">.

=head3 uri_too_long

    use PAGI::Pages qw(uri_too_long);
    my $page = uri_too_long(%options);
    my $class_page = PAGI::Pages->uri_too_long(%options);
    my $configured_page = $pages->uri_too_long(%options);

Returns a deferred 414 C<URI Too Long> application. The stock detail is "The
request URI is too long for the server to process." It accepts the common
error option set and defaults described in L</"ERROR OPTIONS">.

=head3 unsupported_media_type

    use PAGI::Pages qw(unsupported_media_type);
    my $page = unsupported_media_type(%options);
    my $class_page = PAGI::Pages->unsupported_media_type(%options);
    my $configured_page = $pages->unsupported_media_type(%options);

Returns a deferred 415 C<Unsupported Media Type> application. The stock detail
is "The request content type is not supported." It accepts the common error
option set and defaults described in L</"ERROR OPTIONS">.

=head3 range_not_satisfiable

    use PAGI::Pages qw(range_not_satisfiable);
    my $page = range_not_satisfiable(length => 1048576, %options);
    my $class_page = PAGI::Pages->range_not_satisfiable(length => 1048576, %options);
    my $configured_page = $pages->range_not_satisfiable(length => 1048576, %options);

Returns a deferred 416 C<Range Not Satisfiable> application. The stock detail
is "The requested range cannot be satisfied." In addition to the common error
options in L</"ERROR OPTIONS">, it accepts optional C<length>; see
L</"STATUS-SPECIFIC ERROR OPTIONS">.

=head3 expectation_failed

    use PAGI::Pages qw(expectation_failed);
    my $page = expectation_failed(%options);
    my $class_page = PAGI::Pages->expectation_failed(%options);
    my $configured_page = $pages->expectation_failed(%options);

Returns a deferred 417 C<Expectation Failed> application. The stock detail is
"The server cannot meet the request expectation." It accepts the common error
option set and defaults described in L</"ERROR OPTIONS">.

=head3 misdirected_request

    use PAGI::Pages qw(misdirected_request);
    my $page = misdirected_request(%options);
    my $class_page = PAGI::Pages->misdirected_request(%options);
    my $configured_page = $pages->misdirected_request(%options);

Returns a deferred 421 C<Misdirected Request> application. The stock detail is
"The request was sent to a server that cannot respond for this authority." It
accepts the common error option set and defaults described in
L</"ERROR OPTIONS">.

=head3 unprocessable_content

    use PAGI::Pages qw(unprocessable_content);
    my $page = unprocessable_content(%options);
    my $class_page = PAGI::Pages->unprocessable_content(%options);
    my $configured_page = $pages->unprocessable_content(%options);

Returns a deferred 422 C<Unprocessable Content> application. The stock detail
is "The request content could not be processed." It accepts the common error
option set and defaults described in L</"ERROR OPTIONS">.

=head3 locked

    use PAGI::Pages qw(locked);
    my $page = locked(%options);
    my $class_page = PAGI::Pages->locked(%options);
    my $configured_page = $pages->locked(%options);

Returns a deferred 423 C<Locked> application. The stock detail is "The
requested resource is locked." It accepts the common error option set and
defaults described in L</"ERROR OPTIONS">.

=head3 failed_dependency

    use PAGI::Pages qw(failed_dependency);
    my $page = failed_dependency(%options);
    my $class_page = PAGI::Pages->failed_dependency(%options);
    my $configured_page = $pages->failed_dependency(%options);

Returns a deferred 424 C<Failed Dependency> application. The stock detail is
"The request failed because a required operation failed." It accepts the
common error option set and defaults described in L</"ERROR OPTIONS">.

=head3 too_early

    use PAGI::Pages qw(too_early);
    my $page = too_early(%options);
    my $class_page = PAGI::Pages->too_early(%options);
    my $configured_page = $pages->too_early(%options);

Returns a deferred 425 C<Too Early> application. The stock detail is "The
server is unwilling to process this request yet." It accepts the common error
option set and defaults described in L</"ERROR OPTIONS">.

=head3 upgrade_required

    use PAGI::Pages qw(upgrade_required);
    my $page = upgrade_required(upgrade => 'websocket', %options);
    my $class_page = PAGI::Pages->upgrade_required(upgrade => 'websocket', %options);
    my $configured_page = $pages->upgrade_required(upgrade => 'websocket', %options);

Returns a deferred 426 C<Upgrade Required> application. The stock detail is
"The client must use a different protocol for this resource." In addition to
the common options in L</"ERROR OPTIONS">, it accepts C<upgrade>, which is
required unless C<headers> supplies C<Upgrade>. Materialization
requires HTTP/1.1; the PAGI server supplies the companion
C<Connection: upgrade> field. See L</"STATUS-SPECIFIC ERROR OPTIONS">.

=head3 precondition_required

    use PAGI::Pages qw(precondition_required);
    my $page = precondition_required(%options);
    my $class_page = PAGI::Pages->precondition_required(%options);
    my $configured_page = $pages->precondition_required(%options);

Returns a deferred 428 C<Precondition Required> application. The stock detail
is "The request must include a precondition." It accepts the common error
option set, but its cache policy cannot be weakened from C<no-store>; see
L</"ERROR OPTIONS">.

=head3 too_many_requests

    use PAGI::Pages qw(too_many_requests);
    my $page = too_many_requests(retry_after => 60, %options);
    my $class_page = PAGI::Pages->too_many_requests(retry_after => 60, %options);
    my $configured_page = $pages->too_many_requests(retry_after => 60, %options);

Returns a deferred 429 C<Too Many Requests> application. The stock detail is
"Too many requests have been received in a short time." In addition to the
common options in L</"ERROR OPTIONS">, it accepts optional C<retry_after>. Its
cache policy cannot be weakened from C<no-store>. See
L</"STATUS-SPECIFIC ERROR OPTIONS">.

=head3 request_header_fields_too_large

    use PAGI::Pages qw(request_header_fields_too_large);
    my $page = request_header_fields_too_large(%options);
    my $class_page = PAGI::Pages->request_header_fields_too_large(%options);
    my $configured_page = $pages->request_header_fields_too_large(%options);

Returns a deferred 431 C<Request Header Fields Too Large> application. The
stock detail is "The request header fields are too large." It accepts the
common error option set, but its cache policy cannot be weakened from
C<no-store>; see L</"ERROR OPTIONS">.

=head3 unavailable_for_legal_reasons

    use PAGI::Pages qw(unavailable_for_legal_reasons);
    my $page = unavailable_for_legal_reasons(blocked_by => '/authority', %options);
    my $class_page = PAGI::Pages->unavailable_for_legal_reasons(
        blocked_by => '/authority', %options,
    );
    my $configured_page = $pages->unavailable_for_legal_reasons(
        blocked_by => '/authority', %options,
    );

Returns a deferred 451 C<Unavailable For Legal Reasons> application. The stock
detail is "The resource is unavailable for legal reasons." In addition to the
common options in L</"ERROR OPTIONS">, it accepts optional C<blocked_by>; see
L</"STATUS-SPECIFIC ERROR OPTIONS">.

=head3 internal_server_error

    use PAGI::Pages qw(internal_server_error);
    my $page = internal_server_error(%options);
    my $class_page = PAGI::Pages->internal_server_error(%options);
    my $configured_page = $pages->internal_server_error(%options);

Returns a deferred 500 C<Internal Server Error> application. The stock detail
is "The server encountered an unexpected condition." It accepts the common
error option set and defaults described in L</"ERROR OPTIONS">.

=head3 not_implemented

    use PAGI::Pages qw(not_implemented);
    my $page = not_implemented(%options);
    my $class_page = PAGI::Pages->not_implemented(%options);
    my $configured_page = $pages->not_implemented(%options);

Returns a deferred 501 C<Not Implemented> application. The stock detail is
"The server does not support this request method." It accepts the common error
option set and defaults described in L</"ERROR OPTIONS">.

=head3 bad_gateway

    use PAGI::Pages qw(bad_gateway);
    my $page = bad_gateway(%options);
    my $class_page = PAGI::Pages->bad_gateway(%options);
    my $configured_page = $pages->bad_gateway(%options);

Returns a deferred 502 C<Bad Gateway> application. The stock detail is "The
server received an invalid response from an upstream server." It accepts the
common error option set and defaults described in L</"ERROR OPTIONS">.

=head3 service_unavailable

    use PAGI::Pages qw(service_unavailable);
    my $page = service_unavailable(retry_after => 60, %options);
    my $class_page = PAGI::Pages->service_unavailable(retry_after => 60, %options);
    my $configured_page = $pages->service_unavailable(retry_after => 60, %options);

Returns a deferred 503 C<Service Unavailable> application. The stock detail is
"The server is temporarily unable to handle the request." In addition to the
common options in L</"ERROR OPTIONS">, it accepts optional C<retry_after>; see
L</"STATUS-SPECIFIC ERROR OPTIONS">.

=head3 gateway_timeout

    use PAGI::Pages qw(gateway_timeout);
    my $page = gateway_timeout(%options);
    my $class_page = PAGI::Pages->gateway_timeout(%options);
    my $configured_page = $pages->gateway_timeout(%options);

Returns a deferred 504 C<Gateway Timeout> application. The stock detail is
"The server did not receive a timely response from an upstream server." It
accepts the common error option set and defaults described in
L</"ERROR OPTIONS">.

=head3 http_version_not_supported

    use PAGI::Pages qw(http_version_not_supported);
    my $page = http_version_not_supported(%options);
    my $class_page = PAGI::Pages->http_version_not_supported(%options);
    my $configured_page = $pages->http_version_not_supported(%options);

Returns a deferred 505 C<HTTP Version Not Supported> application. The stock
detail is "The server does not support this HTTP version." It accepts the
common error option set and defaults described in L</"ERROR OPTIONS">.

=head3 variant_also_negotiates

    use PAGI::Pages qw(variant_also_negotiates);
    my $page = variant_also_negotiates(%options);
    my $class_page = PAGI::Pages->variant_also_negotiates(%options);
    my $configured_page = $pages->variant_also_negotiates(%options);

Returns a deferred 506 C<Variant Also Negotiates> application. The stock detail
is "The server found a configuration error while negotiating a response." It
accepts the common error option set and defaults described in
L</"ERROR OPTIONS">.

=head3 insufficient_storage

    use PAGI::Pages qw(insufficient_storage);
    my $page = insufficient_storage(%options);
    my $class_page = PAGI::Pages->insufficient_storage(%options);
    my $configured_page = $pages->insufficient_storage(%options);

Returns a deferred 507 C<Insufficient Storage> application. The stock detail
is "The server cannot store the representation needed to complete the
request." It accepts the common error option set and defaults described in
L</"ERROR OPTIONS">.

=head3 loop_detected

    use PAGI::Pages qw(loop_detected);
    my $page = loop_detected(%options);
    my $class_page = PAGI::Pages->loop_detected(%options);
    my $configured_page = $pages->loop_detected(%options);

Returns a deferred 508 C<Loop Detected> application. The stock detail is "The
server detected an infinite loop while processing the request." It accepts the
common error option set and defaults described in L</"ERROR OPTIONS">.

=head3 network_authentication_required

    use PAGI::Pages qw(network_authentication_required);
    my $page = network_authentication_required(login_url => '/login', %options);
    my $class_page = PAGI::Pages->network_authentication_required(login_url => '/login', %options);
    my $configured_page = $pages->network_authentication_required(login_url => '/login', %options);

Returns a deferred 511 C<Network Authentication Required> application. The
stock detail is "Network authentication is required before access is granted."
In addition to the common options in L</"ERROR OPTIONS">, it accepts optional
C<login_url>. Its cache policy cannot be weakened from C<no-store>, and
C<login> is reserved in C<extensions>. See
L</"STATUS-SPECIFIC ERROR OPTIONS">.

The named set deliberately has no 418 or 510 entry. Use L</status> for another
400--599 code and supply custom problem fields when the code is not registered.

=head2 NAMED REDIRECT METHODS

Named redirects are class and configured-instance methods; they are not
exportable functions. Each requires C<$target>, returns a deferred application,
and accepts the redirect options C<as>, C<detail>, C<headers>,
C<cache_control>, C<preserve_query>, and C<retry_after>. They reject C<status>
even when it matches the method's fixed status. See L</"REDIRECT OPTIONS"> for
all value shapes and defaults.

=head3 moved_permanently

    my $page = PAGI::Pages->moved_permanently($target, %options);
    my $configured_page = $pages->moved_permanently($target, %options);

C<$target> is a required ASCII URI-reference scalar.
Returns a deferred 301 C<Moved Permanently> redirect application.
This method is not exportable. Its complete option set and defaults are in
L</"REDIRECT OPTIONS">.

=head3 found

    my $page = PAGI::Pages->found($target, %options);
    my $configured_page = $pages->found($target, %options);

C<$target> is a required ASCII URI-reference scalar.
Returns a deferred 302 C<Found> redirect application.
This method is not exportable. Its complete option set and defaults are in
L</"REDIRECT OPTIONS">.

=head3 see_other

    my $page = PAGI::Pages->see_other($target, %options);
    my $configured_page = $pages->see_other($target, %options);

C<$target> is a required ASCII URI-reference scalar.
Returns a deferred 303 C<See Other> redirect application.
This method is not exportable. Its complete option set and defaults are in
L</"REDIRECT OPTIONS">.

=head3 temporary_redirect

    my $page = PAGI::Pages->temporary_redirect($target, %options);
    my $configured_page = $pages->temporary_redirect($target, %options);

C<$target> is a required ASCII URI-reference scalar.
Returns a deferred 307 C<Temporary Redirect> application.
This method is not exportable. Its complete option set and defaults are in
L</"REDIRECT OPTIONS">.

=head3 permanent_redirect

    my $page = PAGI::Pages->permanent_redirect($target, %options);
    my $configured_page = $pages->permanent_redirect($target, %options);

C<$target> is a required ASCII URI-reference scalar.
Returns a deferred 308 C<Permanent Redirect> application.
This method is not exportable. Its complete option set and defaults are in
L</"REDIRECT OPTIONS">.

=head1 OPTION REFERENCE

All factory options are flat key/value lists. An odd list, an empty or
reference-valued option name, or an unknown option croaks at factory time.
Option values are copied into the deferred application; caller mutation of
C<headers> or C<extensions> after construction does not change later
responses.

=head2 WELCOME OPTIONS

=over 4

=item * C<as>

C<auto>, C<html>, C<json>, or C<text>. When omitted, the retained policy's
C<as> value applies.

=item * C<headers>

An even-length arrayref C<[name =E<gt> value, ...]>. See
L</"HEADERS AND CACHE POLICY">.

=item * C<cache_control>

An ASCII HTTP field-value scalar. Welcome adds no Cache-Control field when it
is omitted.

=back

=head2 ERROR OPTIONS

Every error accepts these options:

=over 4

=item * C<as>

C<auto>, C<html>, C<json>, or C<text>. When omitted, the retained policy's
C<as> value applies.

=item * C<detail>

A defined, non-reference Unicode scalar. It replaces the stock detail. For an
unregistered generic L</status>, it is required.

=item * C<type> and C<title>

C<type> is an absolute ASCII URI and C<title> is a defined, non-reference
Unicode scalar. On a registered error they must be supplied together or both
omitted. When omitted, Pages uses the stock title and C<about:blank>. An
explicit C<type =E<gt> 'about:blank'> is invalid because an explicit type is a
custom problem type. An unregistered generic L</status> requires both values
and C<detail>.

=item * C<instance>

An ASCII URI-reference scalar. It is omitted from problem JSON by default.

=item * C<extensions>

An unblessed, JSON-encodable hashref, copied into the top level of problem
JSON. C<type>, C<title>, C<status>, C<detail>, and C<instance> are reserved.
Status 511 also reserves C<login>.

=item * C<headers>

An even-length arrayref C<[name =E<gt> value, ...]>. See
L</"HEADERS AND CACHE POLICY">.

=item * C<cache_control>

An ASCII HTTP field-value scalar. Errors default to C<no-store>. Statuses 428,
429, 431, and 511 accept only a case-insensitive, surrounding-space-tolerant
C<no-store> override and always emit canonical C<no-store>.

=back

Status-specific options are accepted only for the statuses listed next.

=head2 STATUS-SPECIFIC ERROR OPTIONS

=over 4

=item * C<challenge> (401 and 407)

A nonempty ASCII field-value scalar or a nonempty arrayref of such values.
Each value becomes a separate C<WWW-Authenticate> line for 401 or
C<Proxy-Authenticate> line for 407. At least one semantic or raw challenge is
required; raw and semantic challenges may coexist.

=item * C<allow> (405)

An HTTP token or arrayref of HTTP tokens. Tokens are uppercased and duplicate
names are removed case-insensitively. An empty arrayref or empty scalar emits
the legal empty C<Allow> field. C<allow> is required unless C<headers> supplies
C<Allow>; the semantic and raw forms conflict.

=item * C<length> (416)

An optional non-negative integer. It is canonicalized by removing leading
zeroes while retaining arbitrarily large decimal values without numeric
truncation. It emits
C<Content-Range: bytes */N> and conflicts with a raw C<Content-Range> field.

=item * C<upgrade> (426)

An HTTP token or nonempty arrayref of tokens. It is required unless C<headers>
supplies C<Upgrade>; the semantic and raw forms conflict. Pages emits
C<Upgrade> but reserves C<Connection> for the server. The response can be
materialized only for an absent/default or explicit C<http_version> of C<1.1>.

=item * C<retry_after> (413, 429, and 503)

Optional non-negative delay seconds or a canonical IMF-fixdate such as
C<Sun, 06 Nov 1994 08:49:37 GMT>. It emits C<Retry-After> and conflicts with a
raw field of that name.

=item * C<blocked_by> (451)

An optional ASCII URI-reference without C<E<lt>> or C<E<gt>>. It emits
C<< Link: <URI>; rel="blocked-by" >> and conflicts with a raw C<Link> field.

=item * C<login_url> (511)

An optional ASCII URI-reference. Stock HTML and text render a login link, and
problem JSON receives the authoritative C<login> member.

=back

=head2 REDIRECT OPTIONS

The generic and named redirect factories accept:

=over 4

=item * C<as>

C<auto>, C<html>, C<json>, or C<text>. When omitted, the retained policy's
C<as> value applies.

=item * C<status>

Generic L</redirect> only: 301, 302, 303, 307, or 308. It defaults to 302.
Named redirect methods reject this option.

=item * C<detail>

A defined, non-reference Unicode scalar. It defaults to "The requested
resource has moved."

=item * C<headers>

An even-length arrayref C<[name =E<gt> value, ...]>. See
L</"HEADERS AND CACHE POLICY">.

=item * C<cache_control>

An ASCII HTTP field-value scalar. Redirects add no Cache-Control field when it
is omitted.

=item * C<preserve_query>

The scalar C<0> or C<1>; defaults to C<0>. When true, the raw invocation
C<query_string> is appended before the target's first fragment without
decoding or re-encoding. An unsafe query string croaks during materialization.
The final URI-reference is shared by the Location field and rendered body.

=item * C<retry_after>

Optional non-negative delay seconds or a canonical IMF-fixdate. It emits
C<Retry-After> and conflicts with a raw field of that name.

=back

=head2 HEADERS AND CACHE POLICY

C<headers> must be an even-length arrayref C<[name =E<gt> value, ...]>.
Names are ASCII HTTP tokens. Values are ASCII field-value scalars containing
only bytes C<0x20> through C<0x7e>; controls, wide characters, and references
are rejected. Repeated names are allowed where their HTTP field permits them.

Pages reserves C<Content-Type>, C<Content-Length>, C<Transfer-Encoding>,
C<Location>, C<Cache-Control>, and C<Connection>, case-insensitively. Supply
cache policy through C<cache_control> and redirect targets through the
positional C<$target>. C<Vary> is caller-controlled except that automatic
negotiation merges C<Accept> into it once.

=head2 VALIDATION AND ERROR TIMING

Factories validate option-list shape, names, ordinary values, error field
requirements, redirect target, and most conflicts before returning the
application. They return the application before inspecting any request scope
or calling a renderer.

Scope/source validation, automatic negotiation, preserved query validation,
and the 426 HTTP/1.1 rule occur in C<response_for> or application invocation.
Presentation hooks also run then, so a Future-valued hook, invalid hook return,
or JSON encoding failure is a materialization-time error. These failures occur
before response start when the application is invoked.

=head1 CONTENT NEGOTIATION

Automatic negotiation offers HTML, JSON, and text. Errors use
C<application/problem+json>; welcome and redirects use ordinary
C<application/json>. Repeated Accept fields are combined in wire order.
Automatic selection merges C<Accept> into all existing C<Vary> fields, keeping
first spelling and order, deduplicating case-insensitively, and reducing any
wildcard-containing value to C<*>. Malformed existing members raise. A fixed
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

Pages does not join repeated C<WWW-Authenticate> field lines.

Errors default to C<Cache-Control: no-store>. Statuses 428, 429, 431, and 511
cannot weaken that policy. Welcome and redirects add no cache field by default.

=head1 PRESENTATION HOOKS

Subclasses may override:

    my $html = $self->render_html($descriptor);
    my $text = $self->render_text($descriptor);
    my $problem = $self->render_problem($descriptor);
    my $json = $self->render_json($descriptor);
    my $href = $self->favicon_href($descriptor);

Hooks run synchronously during response materialization and receive a fresh
request-local descriptor. C<render_html> and C<render_text> may receive any
kind and must return a defined, non-reference Unicode scalar.
C<render_problem> receives only an error descriptor and must return an
unblessed hashref. C<render_json> receives only a welcome or redirect
descriptor and must return an unblessed hashref. C<favicon_href>, called by the
stock C<render_html>, must return an ASCII URI-reference scalar or C<undef>.
No hook may return a Future.

Descriptor keys are:

=over 4

=item * welcome

C<kind>, C<status>, C<title>, C<detail>, C<documentation>, C<as>, C<headers>,
and C<cache_control>.

=item * error

C<kind>, C<status>, C<title>, C<detail>, C<type>, C<instance>, C<extensions>,
C<as>, C<headers>, C<cache_control>, C<login_url>, and
C<upgrade_connection>.

=item * redirect

C<kind>, C<status>, C<title>, C<detail>, C<location>, C<as>, C<headers>, and
C<cache_control>.

=back

Pages owns the concrete Response status, headers, cache policy, and selected
representation regardless of hook output. After C<render_problem>, it restores
C<type>, C<title>, C<status>, and C<detail>; it restores or removes
C<instance>; and for 511 it restores or removes C<login>. Other returned
problem members remain. After redirect C<render_json>, Pages restores
C<status> and C<location>; other returned members remain. Welcome JSON is the
returned hash. HTML and text hooks own the complete body string.

For example, a subclass can replace text presentation while leaving policy
and fields intact:

    package MyApp::Pages;
    use parent 'PAGI::Pages';

    sub render_text {
        my ($self, $page) = @_;
        return "$page->{status} $page->{title}: $page->{detail}\n";
    }

    my $page = MyApp::Pages->not_found(as => 'text');

Stock HTML escapes dynamic values and embeds an exact-status SVG favicon.
C<favicon_href> may return a URI-reference or C<undef>. A complete
C<render_html> override owns the entire document and favicon inclusion.

=head1 APPLICATION AND POLICY OWNERSHIP

A Request handler may derive ordinary option values and return the application:

    sub missing {
        my ($request) = @_;
        return PAGI::Pages->not_found(
            as      => 'text',
            detail  => 'Missing ' . $request->path,
            headers => ['X-Request-ID' => request_id()],
        );
    }

At a native triplet boundary use L<PAGI::Utils/invoke_app>:

    await invoke_app($pages_application, $scope, $receive, $send);

The factory result retains the exact Pages policy object. Pages does not clone,
freeze, reconstruct, or inspect arbitrary subclass storage. Deliberate later
policy mutation may affect later invocations, and renderer-maintained subclass
state remains subclass-owned. Each request-scope invocation still creates its own fresh
descriptor and concrete Response. Concurrent mutation while an invocation
derives those values is unsupported.

Pages performs no filesystem or network I/O, dynamic catalog lookup, template
discovery, or transport adaptation. Fetch asynchronous application data before
calling Pages.

=head1 SEE ALSO

L<PAGI::Response>, L<PAGI::Routing>, L<PAGI::Request>,
L<PAGI::WebSocket>, L<PAGI::SSE>, L<PAGI::Pages::Application>

=cut
