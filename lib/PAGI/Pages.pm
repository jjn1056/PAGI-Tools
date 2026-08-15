package PAGI::Pages;

use strict;
use warnings;

use Carp qw(croak);
use Encode qw(encode FB_CROAK);
use Future;
use JSON::MaybeXS ();
use Scalar::Util qw(blessed);

use PAGI::Pages::_Catalog;
use PAGI::Request;
use PAGI::Request::Negotiate;
use PAGI::Response;

my %REPRESENTATION = map { $_ => 1 } qw(auto html json text);
my %DEFAULT_REPRESENTATION = map { $_ => 1 } qw(html json text);
my %WELCOME_OPTION = map { $_ => 1 } qw(as headers cache_control);
my %ERROR_OPTION = map { $_ => 1 } qw(
    as detail type title instance extensions headers cache_control
);
my %PROBLEM_MEMBER = map { $_ => 1 } qw(type title status detail instance);

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
            return $self->_response_for($scope, $descriptor_factory->());
        }

        if (@call && _is_scope_candidate($call[0])) {
            my $scope = _scope_from_source($call[0]);
            if (@call == 1) {
                return $self->_response_for($scope, $descriptor_factory->());
            }
            if (@call == 3
                    && ref($call[1]) eq 'CODE'
                    && ref($call[2]) eq 'CODE') {
                my $response = $self->_response_for(
                    $scope, $descriptor_factory->(),
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
            if $lower eq 'content-length' || $lower eq 'transfer-encoding';
    }
    return \@copy;
}

sub _validate_field_value {
    my ($label, $value) = @_;
    croak "PAGI::Pages $label must be a field-value scalar"
        unless defined($value) && !ref($value)
            && $value !~ /[\x00-\x08\x0A-\x1F\x7F]/;
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

sub _error_factory {
    my ($status, $opts) = @_;
    my $entry = PAGI::Pages::_Catalog->_entry($status);
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
            headers       => exists($opts->{headers}) ? [@{$opts->{headers}}] : [],
            cache_control => $opts->{cache_control},
        };
    };
}

sub _response_for {
    my ($self, $scope, $page) = @_;
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
        $body = eval { JSON::MaybeXS::encode_json(\%problem) };
        croak "PAGI::Pages could not encode problem JSON: $@" if $@;
        $content_type = 'application/problem+json';
    }
    else {
        my $rendered = $self->render_json($hook_page);
        _reject_future($rendered);
        croak 'render_json must return a hashref'
            unless ref($rendered) eq 'HASH' && !blessed($rendered);
        $body = eval { JSON::MaybeXS::encode_json($rendered) };
        croak "PAGI::Pages could not encode JSON: $@" if $@;
        $content_type = 'application/json';
    }

    my $response = PAGI::Response->new($scope);
    $response->status($page->{status});
    my @headers = @{$page->{headers} || []};
    while (@headers) {
        my ($name, $value) = splice(@headers, 0, 2);
        $response->header($name, $value);
    }
    $response->headers->set('Cache-Control', $page->{cache_control})
        if defined $page->{cache_control};
    _merge_vary_accept($response) if $self->_effective_as($page) eq 'auto';
    $response->headers->set('Content-Type', $content_type);
    $response->send_raw($body);
    return $response;
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

    my $accept = PAGI::Request->new($scope)->header('accept');
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
    my ($response) = @_;
    my (@tokens, %seen);
    for my $value ($response->headers->get_all('Vary')) {
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
    $response->headers->set('Vary', join(', ', @tokens));
    return;
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
    return $page->{status} . ' ' . $page->{title} . "\n\n"
        . $page->{detail} . "\n";
}

sub render_problem {
    my ($self, $page) = @_;
    my %problem = %{$page->{extensions} || {}};
    $problem{type} = $page->{type};
    $problem{title} = $page->{title};
    $problem{status} = $page->{status};
    $problem{detail} = $page->{detail};
    $problem{instance} = $page->{instance} if defined $page->{instance};
    return \%problem;
}

sub render_json {
    my ($self, $page) = @_;
    return {
        title         => $page->{title},
        detail        => $page->{detail},
        documentation => $page->{documentation},
    };
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
