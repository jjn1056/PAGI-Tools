use strict;
use warnings;

use Test2::V0;
use Encode qw(decode FB_CROAK);
use Future;
use JSON::MaybeXS qw(decode_json);

use PAGI::Pages;
use PAGI::Utils qw(invoke_app);

my $WELCOME_TITLE = 'Welcome to PAGI';
my $WELCOME_DETAIL = 'PAGI is a spiritual successor to PSGI for asynchronous Perl applications. '
    . 'It connects servers, frameworks, and applications across HTTP, WebSocket, and '
    . 'Server-Sent Events.';
my $WELCOME_LABEL = 'Read the PAGI documentation ' . chr(0x2192);
my $WELCOME_URL = 'https://metacpan.org/pod/PAGI';
my @NAMED_ERRORS = (
    [400 => 'bad_request', 'Bad Request'],
    [401 => 'unauthorized', 'Unauthorized'],
    [402 => 'payment_required', 'Payment Required'],
    [403 => 'forbidden', 'Forbidden'],
    [404 => 'not_found', 'Not Found'],
    [405 => 'method_not_allowed', 'Method Not Allowed'],
    [406 => 'not_acceptable', 'Not Acceptable'],
    [407 => 'proxy_authentication_required', 'Proxy Authentication Required'],
    [408 => 'request_timeout', 'Request Timeout'],
    [409 => 'conflict', 'Conflict'],
    [410 => 'gone', 'Gone'],
    [411 => 'length_required', 'Length Required'],
    [412 => 'precondition_failed', 'Precondition Failed'],
    [413 => 'content_too_large', 'Content Too Large'],
    [414 => 'uri_too_long', 'URI Too Long'],
    [415 => 'unsupported_media_type', 'Unsupported Media Type'],
    [416 => 'range_not_satisfiable', 'Range Not Satisfiable'],
    [417 => 'expectation_failed', 'Expectation Failed'],
    [421 => 'misdirected_request', 'Misdirected Request'],
    [422 => 'unprocessable_content', 'Unprocessable Content'],
    [423 => 'locked', 'Locked'],
    [424 => 'failed_dependency', 'Failed Dependency'],
    [425 => 'too_early', 'Too Early'],
    [426 => 'upgrade_required', 'Upgrade Required'],
    [428 => 'precondition_required', 'Precondition Required'],
    [429 => 'too_many_requests', 'Too Many Requests'],
    [431 => 'request_header_fields_too_large', 'Request Header Fields Too Large'],
    [451 => 'unavailable_for_legal_reasons', 'Unavailable For Legal Reasons'],
    [500 => 'internal_server_error', 'Internal Server Error'],
    [501 => 'not_implemented', 'Not Implemented'],
    [502 => 'bad_gateway', 'Bad Gateway'],
    [503 => 'service_unavailable', 'Service Unavailable'],
    [504 => 'gateway_timeout', 'Gateway Timeout'],
    [505 => 'http_version_not_supported', 'HTTP Version Not Supported'],
    [506 => 'variant_also_negotiates', 'Variant Also Negotiates'],
    [507 => 'insufficient_storage', 'Insufficient Storage'],
    [508 => 'loop_detected', 'Loop Detected'],
    [511 => 'network_authentication_required', 'Network Authentication Required'],
);

sub http_scope {
    my (%args) = @_;
    my @headers;
    push @headers, ['Accept' => $args{accept}] if defined $args{accept};
    return {
        type         => 'http',
        method       => 'GET',
        path         => '/',
        headers      => \@headers,
        http_version => '1.1',
        query_string => '',
    };
}

sub send_response {
    my ($application, $scope) = @_;
    $scope ||= http_scope();
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    Future->wrap(invoke_app(
        $application, $scope, sub { Future->done }, $send,
    ))->get;
    return \@events;
}

sub invoke_error {
    my ($application, $scope) = @_;
    $scope ||= http_scope();
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    my $error = dies {
        Future->wrap(invoke_app(
            $application, $scope, sub { Future->done }, $send,
        ))->get;
    };
    return ($error, \@events);
}

sub header_values {
    my ($events, $name) = @_;
    my $wanted = lc $name;
    return map { $_->[1] }
        grep { lc($_->[0]) eq $wanted }
        @{$events->[0]{headers} || []};
}

sub header {
    my ($events, $name) = @_;
    my @values = header_values($events, $name);
    return @values ? $values[-1] : undef;
}

sub body {
    my ($events) = @_;
    return $events->[1]{body};
}

sub decode_data_uri {
    my ($uri) = @_;
    $uri =~ s/\Adata:image\/svg\+xml,//;
    $uri =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $uri;
}

sub html_favicon_href {
    my ($html) = @_;
    my ($href) = $html =~ m{<link\s+rel="icon"\s+type="image/svg\+xml"\s+href="([^"]+)"}i;
    return $href;
}

{
    package Local::ProblemHookPages;
    our @ISA = ('PAGI::Pages');
    sub render_problem {
        my ($self, $page) = @_;
        $page->{type} = 'https://mutated.test/problem';
        $page->{title} = 'Mutated';
        $page->{status} = 499;
        $page->{detail} = 'Mutated detail';
        $page->{instance} = '/mutated';
        return {
            type => 'https://wrong.test/problem', title => 'Wrong',
            status => 499, detail => 'Wrong detail', hook_extension => 'kept',
            instance => '/invented',
        };
    }
}

{
    package Local::WelcomeJSONPages;
    our @ISA = ('PAGI::Pages');
    sub render_json { return { title => 'Subclass welcome', custom => 1 } }
}

{
    package Local::TextHookPages;
    our @ISA = ('PAGI::Pages');
    sub render_text {
        my ($self, $page) = @_;
        return "hook:$page->{status}:$page->{title}\n";
    }
}

{
    package Local::CustomFaviconPages;
    our @ISA = ('PAGI::Pages');
    our @SEEN_STATUS;
    sub favicon_href {
        my ($self, $page) = @_;
        push @SEEN_STATUS, $page->{status};
        return '/assets/status.svg?theme=light&v=1';
    }
}

{
    package Local::NoFaviconPages;
    our @ISA = ('PAGI::Pages');
    sub favicon_href { return undef }
}

{
    package Local::OwnedHTMLPages;
    our @ISA = ('PAGI::Pages');
    sub render_html { return '<!doctype html><html lang="en"><p>owned</p></html>' }
    sub favicon_href { die "favicon_href must not be called\n" }
}

{
    package Local::FutureTextPages;
    our @ISA = ('PAGI::Pages');
    sub render_text { return Future->done('late text') }
}

{
    package Local::FutureHTMLPages;
    our @ISA = ('PAGI::Pages');
    sub render_html { return Future->done('<p>late HTML</p>') }
}

{
    package Local::FutureProblemPages;
    our @ISA = ('PAGI::Pages');
    sub render_problem { return Future->done({ status => 404 }) }
}

{
    package Local::FutureJSONPages;
    our @ISA = ('PAGI::Pages');
    sub render_json { return Future->done({ title => 'late JSON' }) }
}

{
    package Local::FutureFaviconPages;
    our @ISA = ('PAGI::Pages');
    sub favicon_href { return Future->done('/late.svg') }
}

{
    package Local::ControlFaviconPages;
    our @ISA = ('PAGI::Pages');
    sub favicon_href { return "/bad\nfavicon.svg" }
}

{
    package Local::BadJSONPages;
    our @ISA = ('PAGI::Pages');
    sub render_problem {
        my $value = {};
        $value->{cycle} = $value;
        return $value;
    }
}

{
    package Local::BadShapePages;
    our @ISA = ('PAGI::Pages');
    sub render_problem { return [] }
}

{
    package Local::NestedMutationPages;
    our @ISA = ('PAGI::Pages');
    sub render_problem {
        my ($self, $page) = @_;
        my $seen = $page->{extensions}{metadata}{token};
        $page->{extensions}{metadata}{token} = 'mutated by renderer';
        my $problem = $self->SUPER::render_problem($page);
        $problem->{seen_token} = $seen;
        return $problem;
    }
}

subtest 'body-forbidden descriptors use the concrete Empty response' => sub {
    my $response = PAGI::Pages->new->_response_for(http_scope(), {
        kind => 'welcome', status => 204, title => 'No Content', detail => '',
        documentation => $WELCOME_URL, as => 'text', headers => [],
        cache_control => undef,
    });
    is(ref($response), 'PAGI::Response::Empty',
        'body-forbidden policy selects the exact Empty class');
    is($response->body, '', 'Empty retains an exact zero-byte body');
    ok(!$response->has_content_type,
        'Empty does not manufacture representation metadata');
};

subtest 'auto negotiation selects the documented representation families' => sub {
    my $application = PAGI::Pages->not_found;
    my @cases = (
        [undef,                      'text/html; charset=utf-8'],
        ['*/*',                      'text/html; charset=utf-8'],
        ['text/plain',               'text/plain; charset=utf-8'],
        ['application/problem+json', 'application/problem+json'],
        ['application/json',         'application/problem+json'],
        ['text/html;q=0, */*;q=1',   'application/problem+json'],
    );
    for my $case (@cases) {
        my ($accept, $expected) = @$case;
        my $events = send_response(
            $application, http_scope(accept => $accept),
        );
        is(header($events, 'Content-Type'), $expected,
            defined $accept ? "Accept $accept selects $expected" : "missing Accept selects $expected");
        is(header($events, 'Vary'), 'Accept', 'auto negotiation emits Vary: Accept');
    }

    my $json_default = PAGI::Pages->new(default => 'json');
    my $tie = send_response($json_default->not_found,
        http_scope(accept => 'text/html, application/problem+json, text/plain'));
    is(header($tie, 'Content-Type'), 'application/problem+json',
        'equal effective quality prefers the configured default first');

    my $text_default = PAGI::Pages->new(default => 'text');
    my $rejected = send_response($text_default->not_found, http_scope(
        accept => 'text/html;q=0, application/problem+json;q=0, '
            . 'application/json;q=0, text/plain;q=0'));
    is(header($rejected, 'Content-Type'), 'text/plain; charset=utf-8',
        'total rejection falls back to the configured default');

    my $exact_problem_rejection = send_response($application,
        http_scope(accept => 'application/problem+json;q=0, application/json, text/plain;q=0.5'));
    is(header($exact_problem_rejection, 'Content-Type'), 'text/plain; charset=utf-8',
        'application/json alias cannot revive an exact problem+json exclusion');

    my $repeated_scope = http_scope();
    $repeated_scope->{headers} = [
        ['Accept' => 'text/plain'],
        ['Accept' => 'text/html;q=0'],
    ];
    my $repeated = send_response($application, $repeated_scope);
    is(header($repeated, 'Content-Type'), 'text/plain; charset=utf-8',
        'repeated Accept fields are combined in wire order');

    my $later_winner_scope = http_scope();
    $later_winner_scope->{headers} = [
        ['Accept' => 'application/xml'],
        ['Accept' => 'text/plain'],
    ];
    my $later_winner = send_response($application, $later_winner_scope);
    is(header($later_winner, 'Content-Type'), 'text/plain; charset=utf-8',
        'a later repeated Accept field can supply the winning supported type');
};

subtest 'fixed representation ignores Accept and does not add Vary' => sub {
    my $events = send_response(
        PAGI::Pages->new(as => 'json')->not_found(as => 'text'),
        http_scope(accept => 'text/html'),
    );
    is(header($events, 'Content-Type'), 'text/plain; charset=utf-8',
        'per-call fixed representation overrides policy and ignores Accept');
    is(header($events, 'Vary'), undef, 'fixed representation omits Vary');
};

subtest 'auto Vary merge is case-insensitive and duplicate-free' => sub {
    my $events = send_response(PAGI::Pages->not_found(
        headers => ['Vary' => 'Origin, accept', 'vary' => 'User-Agent, ACCEPT'],
    ), http_scope(accept => 'text/plain'));
    my @vary_fields = header_values($events, 'Vary');
    is(scalar @vary_fields, 1, 'Vary is normalized to one field');
    my @tokens = map {
        my $token = $_;
        $token =~ s/^\s+|\s+$//g;
        lc $token;
    } split /,/, $vary_fields[0];
    is([sort @tokens], [sort qw(origin accept user-agent)],
        'existing Vary tokens are retained without duplicate Accept tokens');
};

subtest 'configured policy negotiates only when the deferred app is invoked' => sub {
    my $pages = PAGI::Pages->new(as => 'auto', default => 'text');
    my $application = $pages->welcome;
    my $events = send_response(
        $application, http_scope(accept => 'application/json'),
    );
    is(header($events, 'Content-Type'), 'application/json',
        'configured Pages application negotiates JSON from invocation scope');
    is(decode_json(body($events))->{title}, $WELCOME_TITLE,
        'negotiated invocation retains the welcome document');
};

subtest 'welcome is not a problem document and preserves exact stock copy' => sub {
    my $auto = PAGI::Pages->welcome;
    my $problem_only = send_response(
        $auto, http_scope(accept => 'application/problem+json'),
    );
    is(header($problem_only, 'Content-Type'), 'text/html; charset=utf-8',
        'problem+json alone does not select welcome JSON');

    my $json_events = send_response(
        $auto, http_scope(accept => 'application/json'),
    );
    is(header($json_events, 'Content-Type'), 'application/json',
        'welcome JSON emits ordinary application/json');
    is(decode_json(body($json_events)), {
        title => $WELCOME_TITLE,
        detail => $WELCOME_DETAIL,
        documentation => $WELCOME_URL,
    }, 'welcome JSON uses the exact ordinary-document shape');

    my $text_events = send_response(PAGI::Pages->welcome(as => 'text'));
    is(decode('UTF-8', body($text_events), FB_CROAK),
        "$WELCOME_TITLE\n\n$WELCOME_DETAIL\n\n$WELCOME_LABEL\n$WELCOME_URL\n",
        'welcome text contains exact copy, label, URL, and one final newline');

    my $html_events = send_response(PAGI::Pages->welcome(as => 'html'));
    my $html = decode('UTF-8', body($html_events), FB_CROAK);
    like($html, qr/<!doctype html>/i, 'welcome HTML is a complete HTML5 document');
    like($html, qr/<html lang="en">/, 'welcome HTML declares English');
    like($html, qr/\Q$WELCOME_TITLE\E/, 'welcome HTML contains the exact title');
    like($html, qr/\Q$WELCOME_DETAIL\E/, 'welcome HTML contains the exact detail');
    like($html, qr{href="\Q$WELCOME_URL\E"[^>]*>\Q$WELCOME_LABEL\E</a>},
        'welcome HTML contains the exact documentation link');
};

subtest 'stock error text, HTML escaping, and UTF-8 length are stable' => sub {
    my $stock = send_response(PAGI::Pages->not_found(as => 'text'));
    is(decode('UTF-8', body($stock), FB_CROAK),
        "404 Not Found\n\nThe requested resource was not found.\n",
        'stock error text has stable layout and exactly one terminal newline');

    my $escaped = send_response(PAGI::Pages->not_found(
        as => 'html',
        type => 'https://example.test/problems/custom',
        title => '<Unsafe & "title">',
        detail => '<script>alert("x")</script> & more',
    ));
    my $html = decode('UTF-8', body($escaped), FB_CROAK);
    like($html, qr/&lt;Unsafe &amp; &quot;title&quot;&gt;/,
        'dynamic title is HTML escaped');
    like($html, qr/&lt;script&gt;alert\(&quot;x&quot;\)&lt;\/script&gt; &amp; more/,
        'dynamic detail is HTML escaped');
    unlike($html, qr/<script>/, 'stock HTML never emits a dynamic script element');

    my $unicode = send_response(PAGI::Pages->not_found(
        as => 'text', detail => "Caf\x{e9} \x{2615}"));
    is(header($unicode, 'Content-Length'), length(body($unicode)),
        'Content-Length is calculated from encoded UTF-8 bytes');
    like(decode('UTF-8', body($unicode), FB_CROAK), qr/Caf\x{e9} \x{2615}/,
        'Unicode hook text is strictly encoded as UTF-8');
};

subtest 'problem JSON has standard members, optional instance, and extensions' => sub {
    my $events = send_response(PAGI::Pages->not_found(
        as => 'json', instance => '/requests/abc',
        extensions => { trace_id => 'trace-1', retryable => 0 },
    ));
    is(header($events, 'Content-Type'), 'application/problem+json',
        'error JSON emits problem+json');
    is(decode_json(body($events)), {
        type => 'about:blank', title => 'Not Found', status => 404,
        detail => 'The requested resource was not found.',
        instance => '/requests/abc', trace_id => 'trace-1', retryable => 0,
    }, 'problem standard members and extensions are emitted at top level');

    my $without_instance = decode_json(body(send_response(
        PAGI::Pages->not_found(as => 'json'))));
    ok(!exists $without_instance->{instance}, 'instance is omitted when not supplied');

    my $hooked = decode_json(body(send_response(
        Local::ProblemHookPages->not_found(as => 'json'))));
    is($hooked, {
        type => 'about:blank', title => 'Not Found', status => 404,
        detail => 'The requested resource was not found.',
        hook_extension => 'kept',
    }, 'base class reasserts standard members and removes an invented instance');
};

subtest 'every named error renders its own registered status semantics' => sub {
    my %required_options = (
        unauthorized                  => [challenge => 'Basic realm="test"'],
        method_not_allowed            => [allow => []],
        proxy_authentication_required => [challenge => 'Basic realm="proxy"'],
        upgrade_required              => [upgrade => 'websocket'],
    );
    for my $named (@NAMED_ERRORS) {
        my ($status, $method, $title) = @$named;
        my $events = send_response(PAGI::Pages->$method(
            as => 'json', @{$required_options{$method} || []}));
        my $problem = decode_json(body($events));
        is($events->[0]{status}, $status, "$method emits status $status");
        is($problem->{title}, $title, "$method emits its registered title");
        ok(defined($problem->{detail}) && length($problem->{detail}),
            "$method emits a nonempty safe detail");
    }

    my $registered = decode_json(body(send_response(PAGI::Pages->status(
        404, as => 'json'))));
    is($registered->{status}, 404, 'general status accepts a registered catalog error');
    is($registered->{title}, 'Not Found',
        'general registered status uses the catalog title');
};

subtest 'problem semantics and extensions are validated before rendering' => sub {
    like(dies { PAGI::Pages->not_found(
        type => 'https://example.test/problems/custom') },
        qr/type and title must be supplied together/,
        'registered status rejects a custom type without title');
    like(dies { PAGI::Pages->not_found(title => 'Custom') },
        qr/type and title must be supplied together/,
        'registered status rejects a custom title without type');
    like(dies {
        PAGI::Pages->not_found(
            type => 'relative/problem', title => 'Custom')
    }, qr/type must be an absolute URI/, 'custom problem type must be absolute');
    like(dies {
        PAGI::Pages->not_found(
            type => 'about:blank', title => 'Custom')
    }, qr/type cannot be about:blank/, 'custom problem type cannot use about:blank');
    like(dies {
        PAGI::Pages->not_found(
            type => "https://example.test/problems/\x{2603}", title => 'Custom')
    }, qr/type must be an absolute URI/,
        'custom problem type requires an ASCII wire URI');

    for my $reserved (qw(type title status detail instance)) {
        like(dies { PAGI::Pages->not_found(
            extensions => {$reserved => 'replace'}) },
            qr/reserved problem member/, "$reserved cannot be supplied as an extension");
    }
    like(dies { PAGI::Pages->not_found(
        instance => "bad\ninstance") },
        qr/instance must be a URI-reference scalar/,
        'instance rejects control characters');
    like(dies { PAGI::Pages->not_found(
        instance => "/requests/\x{2603}") },
        qr/instance must be a URI-reference scalar/,
        'instance requires an ASCII wire URI-reference');
};

subtest 'subclass rendering hooks dispatch through the invoked policy' => sub {
    my $text = send_response(Local::TextHookPages->not_found(
        as => 'text'));
    is(body($text), 'hook:404:Not Found' . "\n",
        'subclass class call dispatches to render_text');

    my $welcome = send_response(Local::WelcomeJSONPages->welcome(
        as => 'json'));
    is(decode_json(body($welcome)), { title => 'Subclass welcome', custom => 1 },
        'welcome JSON dispatches through render_json');
};

subtest 'nested extension values are isolated from callers and hooks' => sub {
    my $extensions = { metadata => { token => 'original' } };
    my $application = Local::NestedMutationPages->not_found(
        as => 'json', extensions => $extensions,
    );
    my $first = decode_json(body(send_response(
        $application,
    )));
    my $second = decode_json(body(send_response(
        $application,
    )));
    is($first->{seen_token}, 'original',
        'first call receives a safe copy of the extension value');
    is($second->{seen_token}, 'original',
        'renderer mutation cannot leak into a later call');
    is($extensions, { metadata => { token => 'original' } },
        'renderer mutation cannot reach the caller-owned structure');
};

subtest 'stock favicon is inline exact-status SVG with documented seams' => sub {
    my $registered_html = decode('UTF-8', body(send_response(
        PAGI::Pages->not_found(as => 'html'))), FB_CROAK);
    my $registered_uri = html_favicon_href($registered_html);
    like($registered_uri, qr/^data:image\/svg\+xml,/, 'stock HTML embeds an SVG data URI');
    like(decode_data_uri($registered_uri), qr/404/, 'registered SVG contains exact status 404');
    unlike($registered_html, qr{/favicon\.ico}, 'stock HTML does not request /favicon.ico');
    unlike($registered_html, qr{https?://}, 'stock error HTML loads no external resource');

    my $custom_html = decode('UTF-8', body(send_response(PAGI::Pages->status(
        599, as => 'html',
        type => 'https://example.test/problems/upstream-timeout',
        title => 'Upstream Timeout', detail => 'The upstream timed out.',
    ))), FB_CROAK);
    like(decode_data_uri(html_favicon_href($custom_html)), qr/599/,
        'custom SVG contains exact status 599 rather than a family label');

    local @Local::CustomFaviconPages::SEEN_STATUS;
    my $same_origin = decode('UTF-8', body(send_response(
        Local::CustomFaviconPages->not_found(as => 'html'))), FB_CROAK);
    is(\@Local::CustomFaviconPages::SEEN_STATUS, [404],
        'favicon_href receives the exact request-local status');
    like($same_origin, qr{href="/assets/status\.svg\?theme=light&amp;v=1"},
        'custom same-origin favicon URI is HTML-attribute escaped');

    my $omitted = decode('UTF-8', body(send_response(
        Local::NoFaviconPages->not_found(as => 'html'))), FB_CROAK);
    unlike($omitted, qr/<link\s+rel="icon"/, 'undef favicon omits the link element');
};

subtest 'full HTML overrides own favicon inclusion' => sub {
    my $events = send_response(Local::OwnedHTMLPages->not_found(
        as => 'html'));
    is(body($events), '<!doctype html><html lang="en"><p>owned</p></html>',
        'base class preserves the complete override document');
    unlike(body($events), qr/<link\s+rel="icon"/,
        'base class does not inject a favicon into a full override');
};

subtest 'renderer failures and Future-valued hooks occur before send' => sub {
    my @cases = (
        [sub { Local::FutureHTMLPages->not_found(as => 'html') },
            qr/renderer must return an immediate value/, 'Future HTML renderer'],
        [sub { Local::FutureTextPages->not_found(as => 'text') },
            qr/renderer must return an immediate value/, 'Future text renderer'],
        [sub { Local::FutureProblemPages->not_found(as => 'json') },
            qr/renderer must return an immediate value/, 'Future problem renderer'],
        [sub { Local::FutureJSONPages->welcome(as => 'json') },
            qr/renderer must return an immediate value/, 'Future JSON renderer'],
        [sub { Local::FutureFaviconPages->not_found(as => 'html') },
            qr/renderer must return an immediate value/, 'Future favicon hook'],
        [sub { Local::ControlFaviconPages->not_found(as => 'html') },
            qr/favicon_href.*URI-reference/i, 'control-bearing favicon hook'],
        [sub { Local::BadJSONPages->not_found(as => 'json') },
            qr/(?:circular|JSON|encode)/i, 'JSON encoding failure'],
        [sub { Local::BadShapePages->not_found(as => 'json') },
            qr/render_problem must return a hashref/, 'invalid renderer shape'],
    );
    for my $case (@cases) {
        my ($build, $error, $label) = @$case;
        my $application;
        is(dies { $application = $build->() }, undef,
            "$label does not render at factory time");
        my ($caught, $events) = invoke_error($application);
        like($caught, $error, "$label is rejected at invocation time");
        is($events, [], "$label emits no response event");
    }
};

subtest 'factories expose a reusable application rather than a mutable Response' => sub {
    my $application = PAGI::Pages->not_found(
        as => 'text', headers => ['X-Request-ID' => 'request-17'],
    );
    ok(!$application->can('header'), 'deferred application exposes no Response mutation API');
    my $events = send_response($application);
    is(header($events, 'X-Request-ID'), 'request-17',
        'captured headers are applied to the request-local Response');
    my $again = send_response($application);
    is(header($again, 'X-Request-ID'), 'request-17',
        'the same application creates an equivalent fresh Response again');
};

done_testing;
