use strict;
use warnings;

use Test2::V0;
use Future;
use JSON::MaybeXS qw(decode_json);
use Scalar::Util qw(refaddr);

use PAGI::Pages;
use PAGI::Pages::_Catalog;
use PAGI::Request;
use PAGI::Routing qw(route mount request_app);
use PAGI::SSE;
use PAGI::WebSocket;

my @CATALOG_FUNCTIONS = map { $_ . '_page' }
    @{PAGI::Pages::_Catalog->_named_methods};
my @COMMON_FUNCTIONS = qw(
    welcome_page status_page redirect_page not_found_page unauthorized_page
    forbidden_page method_not_allowed_page conflict_page too_many_requests_page
    internal_server_error_page bad_gateway_page service_unavailable_page
);
my @ALL_FUNCTIONS = (
    qw(welcome_page status_page redirect_page), @CATALOG_FUNCTIONS,
);

sub http_scope {
    my (%args) = @_;
    return {
        type         => 'http',
        method       => $args{method} || 'GET',
        path         => defined $args{path} ? $args{path} : '/',
        headers      => $args{headers} || [],
        http_version => exists($args{http_version})
            ? $args{http_version} : '1.1',
        query_string => exists($args{query_string})
            ? $args{query_string} : '',
    };
}

sub protocol_scope {
    my ($type, %args) = @_;
    my $scope = http_scope(%args);
    $scope->{type} = $type;
    return $scope;
}

sub http_request {
    my (%args) = @_;
    return PAGI::Request->new(
        http_scope(%args), sub { Future->done },
    );
}

sub run_app {
    my ($app, $scope, $receive) = @_;
    my @events;
    $receive ||= sub { return Future->done };
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    Future->wrap($app->($scope, $receive, $send))->get;
    return \@events;
}

sub response_header {
    my ($events, $name) = @_;
    my $wanted = lc $name;
    for my $pair (@{$events->[0]{headers} || []}) {
        return $pair->[1] if lc($pair->[0]) eq $wanted;
    }
    return;
}

{
    package Local::ScopeBearer;
    sub new { bless { scope => $_[1] }, $_[0] }
    sub scope { shift->{scope} }
}

{
    package Local::CountingPages;
    our @ISA = ('PAGI::Pages');
    our $NEW_COUNT = 0;
    our @RENDERED_BY;

    sub new {
        my $class = shift;
        ++$NEW_COUNT;
        return $class->SUPER::new(@_);
    }

    sub render_text {
        my ($self, $page) = @_;
        push @RENDERED_BY, $self;
        return $self->SUPER::render_text($page);
    }
}

{
    package Local::ConcurrentPages;
    our @ISA = ('PAGI::Pages');
    our @PAGE_IDS;

    sub render_html {
        my ($self, $page) = @_;
        push @PAGE_IDS, $page;
        return $self->SUPER::render_html($page);
    }

    sub render_text {
        my ($self, $page) = @_;
        push @PAGE_IDS, $page;
        return $self->SUPER::render_text($page);
    }
}

subtest 'constructor policy is strict and request-independent' => sub {
    isa_ok(PAGI::Pages->new, ['PAGI::Pages']);
    isa_ok(PAGI::Pages->new(as => 'auto', default => 'html'), ['PAGI::Pages']);

    my @bad = (
        [as => ''], [as => 'xml'], [as => []],
        [default => ''], [default => 'auto'], [default => {}],
        [unknown => 1], ['as'],
    );
    for my $args (@bad) {
        like(dies { PAGI::Pages->new(@$args) }, qr/PAGI::Pages constructor/,
            'invalid constructor input is rejected');
    }

    my $pages = PAGI::Pages->new(as => 'text', default => 'json');
    my $one = $pages->not_found(http_scope());
    my $two = $pages->not_found(http_scope());
    isnt(refaddr($one), refaddr($two), 'instance calls create fresh Responses');
    is(ref($one), 'PAGI::Response::Text',
        'configured instance returns the exact concrete class');
    is(ref($two), 'PAGI::Response::Text',
        'configured policy is reusable without request state');
};

subtest 'exports are opt-in and the common and all bundles are exact' => sub {
    is(\@PAGI::Pages::EXPORT, [], 'Pages exports nothing by default');
    is(\@PAGI::Pages::EXPORT_OK, \@ALL_FUNCTIONS,
        'the optional export list contains every and only page function');
    is($PAGI::Pages::EXPORT_TAGS{common}, \@COMMON_FUNCTIONS,
        ':common contains exactly the approved twelve functions');
    is($PAGI::Pages::EXPORT_TAGS{all}, \@ALL_FUNCTIONS,
        ':all contains exactly the generic and catalog-derived functions');

    my $common_ok = eval q{
        package Local::CommonPageImports;
        PAGI::Pages->import(':common');
        1;
    };
    is($common_ok, 1, ':common imports successfully');
    my $all_ok = eval q{
        package Local::AllPageImports;
        PAGI::Pages->import(':all');
        1;
    };
    is($all_ok, 1, ':all imports successfully');

    for my $name (@ALL_FUNCTIONS) {
        is(Local::CommonPageImports->can($name) ? 1 : 0,
            (grep { $_ eq $name } @COMMON_FUNCTIONS) ? 1 : 0,
            ":common membership for $name is exact");
        ok(Local::AllPageImports->can($name), ":all exports $name");
    }
    ok(!main->can('welcome_page'), 'plain use PAGI::Pages imports no handler');
};

subtest 'class and export forms return the same concrete values' => sub {
    my $request = http_request(headers => [['Accept' => 'text/plain']]);
    my @cases = (
        [welcome_page => sub { PAGI::Pages->welcome($request, as => 'text') },
            'PAGI::Response::Text', 200],
        [not_found_page => sub { PAGI::Pages->not_found($request, as => 'json') },
            'PAGI::Response::Problem', 404],
        [status_page => sub { PAGI::Pages->status($request, 410, as => 'text') },
            'PAGI::Response::Text', 410],
        [redirect_page => sub {
            PAGI::Pages->redirect($request, '/next', status => 308, as => 'json')
        }, 'PAGI::Response::JSON', 308],
    );

    for my $case (@cases) {
        my ($name, $method_call, $class, $status) = @$case;
        my $function = Local::AllPageImports->can($name);
        my $from_function = $name eq 'status_page'
            ? $function->($request, 410, as => 'text')
            : $name eq 'redirect_page'
                ? $function->($request, '/next', status => 308, as => 'json')
                : $name eq 'not_found_page'
                    ? $function->($request, as => 'json')
                    : $function->($request, as => 'text');
        my $from_method = $method_call->();
        is(ref($from_function), $class, "$name returns exact $class identity");
        is($from_function->status, $status, "$name returns status $status");
        if ($class eq 'PAGI::Response::Text') {
            is($from_function->body, $from_method->body,
                "$name bytes agree with its class method");
        }
        else {
            is(decode_json($from_function->body), decode_json($from_method->body),
                "$name JSON value agrees with its class method");
        }
    }
};

subtest 'every page call requires an explicit metadata source' => sub {
    my @methods = (
        qw(welcome status redirect moved_permanently found see_other
           temporary_redirect permanent_redirect),
        @{PAGI::Pages::_Catalog->_named_methods},
    );
    for my $method (@methods) {
        like(dies { PAGI::Pages->$method() },
            qr/explicit.*(?:Request|metadata).*source/i,
            "$method rejects a no-source factory call");
    }
    for my $name (@ALL_FUNCTIONS) {
        my $function = Local::AllPageImports->can($name);
        like(dies { $function->() },
            qr/explicit.*(?:Request|metadata).*source/i,
            "$name requires an explicit source");
    }

    my $pages = PAGI::Pages->new(as => 'text');
    like(dies { $pages->not_found },
        qr/explicit.*(?:Request|metadata).*source/i,
        'configured instances also reject no-source calls');
};

subtest 'Request and protocol metadata sources do not change protocol state' => sub {
    my $request = http_request(headers => [['Accept' => 'text/plain']]);
    is(ref(PAGI::Pages->welcome($request)), 'PAGI::Response::Text',
        'Request metadata negotiates a concrete text response');

    my (@websocket_events, @sse_events);
    my $websocket_scope = protocol_scope(
        'websocket', headers => [['Accept' => 'application/problem+json']],
    );
    my $websocket = PAGI::WebSocket->new(
        $websocket_scope,
        sub { Future->done },
        sub { push @websocket_events, $_[0]; Future->done },
    );
    my $websocket_response = PAGI::Pages->not_found($websocket);
    is(ref($websocket_response), 'PAGI::Response::Problem',
        'WebSocket handshake metadata negotiates a Problem response');
    is(\@websocket_events, [], 'Pages emits no WebSocket events');
    ok(!$websocket->is_connected, 'Pages does not accept the WebSocket');

    my $sse_scope = protocol_scope(
        'sse', headers => [['Accept' => 'text/html']],
    );
    my $sse = PAGI::SSE->new(
        $sse_scope,
        sub { Future->done },
        sub { push @sse_events, $_[0]; Future->done },
    );
    my $sse_response = PAGI::Pages->welcome($sse);
    is(ref($sse_response), 'PAGI::Response::HTML',
        'SSE handshake metadata negotiates an HTML response');
    is(\@sse_events, [], 'Pages emits no SSE events');
    ok(!$sse->is_started, 'Pages does not start SSE');

    is(ref(PAGI::Pages->not_found(
        protocol_scope('websocket'), as => 'text')),
        'PAGI::Response::Text', 'an unblessed WebSocket scope is accepted');
    is(ref(PAGI::Pages->not_found(
        protocol_scope('sse'), as => 'text')),
        'PAGI::Response::Text', 'an unblessed SSE scope is accepted');

    like(dies { PAGI::Pages->not_found(Local::ScopeBearer->new(http_scope())) },
        qr/Request|WebSocket|SSE|scope/i,
        'an arbitrary scope-bearing object is not a supported source');
    like(dies { PAGI::Pages->not_found({ type => 'lifespan' }) },
        qr/http-capable|HTTP.*metadata|lifespan/i,
        'lifespan metadata is rejected');
    like(dies { PAGI::Pages->not_found({ type => 'unknown' }) },
        qr/http-capable|HTTP.*metadata|unknown/i,
        'unknown metadata is rejected');
};

subtest 'source, option, and status validation is explicit' => sub {
    like(dies { PAGI::Pages->not_found({}) }, qr/scope type is required/,
        'missing scope type is rejected');
    like(dies { PAGI::Pages->not_found({ type => [] }) },
        qr/scope type is required/, 'reference scope type is rejected');
    like(dies { PAGI::Pages->not_found([]) },
        qr/explicit.*(?:Request|metadata).*source/i,
        'non-source references are rejected');

    like(dies { PAGI::Pages->not_found(http_scope(), unknown => 1) },
        qr/unknown PAGI::Pages error option/,
        'unknown error options are rejected after the source');
    like(dies { PAGI::Pages->welcome(
        http_scope(), detail => 'not configurable') },
        qr/unknown PAGI::Pages welcome option/,
        'welcome accepts only its documented options');
    like(dies { PAGI::Pages->not_found(http_scope(), 'as') },
        qr/key\/value pairs/, 'odd option lists are rejected');

    for my $bad (399, 600, 'five hundred', []) {
        like(dies { PAGI::Pages->status(http_scope(), $bad) },
            qr/status must be an integer from 400 to 599/,
            'invalid status is rejected after the source');
    }
    like(dies { PAGI::Pages->status(
        http_scope(), 599, detail => 'missing semantics') },
        qr/custom status 599 requires type, title, and detail/,
        'unknown status requires explicit problem semantics');

    my $custom = PAGI::Pages->status(
        http_scope(), 599,
        type => 'https://example.test/problems/upstream-timeout',
        title => 'Upstream Timeout',
        detail => 'The upstream did not answer.',
        as => 'text',
    );
    is($custom->status, 599, 'strict valid custom status returns a Response');

    for my $method (@{PAGI::Pages::_Catalog->_named_methods}) {
        ok(PAGI::Pages->can($method), "$method is an installed class method");
    }
    ok(!PAGI::Pages->can('not_foud'), 'a typo is not dynamically recovered');
};

subtest 'page functions are Request handlers, not native applications' => sub {
    my $welcome_handler = Local::CommonPageImports->can('welcome_page');
    my $not_found_handler = Local::CommonPageImports->can('not_found_page');

    my $route_app = route('/welcome' => $welcome_handler)->to_app;
    my $welcome = run_app($route_app, http_scope(path => '/welcome'));
    is($welcome->[0]{status}, 200,
        'an exported page function works directly as a Route handler');
    like($welcome->[1]{body}, qr/<!doctype html>/i,
        'Route emits the handler-returned concrete Response');

    my @native_events;
    like(dies {
        $not_found_handler->(
            http_scope(), sub { Future->done },
            sub { push @native_events, $_[0]; Future->done },
        );
    }, qr/PAGI::Pages|option|key\/value/i,
        'native three-argument function invocation is rejected');
    is(\@native_events, [], 'rejected native placement emits no event');

    my $native = request_app($not_found_handler);
    my $mounted = mount('/missing', app => $native)->to_app;
    is(run_app($mounted, http_scope(path => '/missing/child'))->[0]{status},
        404, 'request_app explicitly adapts a function for Mount');

    my $raw = sub {
        my ($scope, $receive, $send) = @_;
        my $response = PAGI::Pages->not_found($scope, as => 'text');
        return $response->respond($scope, $receive, $send);
    };
    my $raw_events = run_app($raw, http_scope(path => '/raw'));
    is($raw_events->[0]{status}, 404,
        'a real raw closure constructs then explicitly emits a Response');
    is(response_header($raw_events, 'Content-Type'),
        'text/plain; charset=utf-8', 'raw emission preserves representation');
};

subtest 'configured subclasses are safe across concurrent response sends' => sub {
    local $Local::CountingPages::NEW_COUNT = 0;
    local @Local::CountingPages::RENDERED_BY;
    my $first = Local::CountingPages->not_found(http_scope(), as => 'text');
    my $second = Local::CountingPages->not_found(http_scope(), as => 'text');
    is($Local::CountingPages::NEW_COUNT, 2,
        'each subclass class call constructs a fresh policy instance');
    isnt(refaddr($Local::CountingPages::RENDERED_BY[0]),
        refaddr($Local::CountingPages::RENDERED_BY[1]),
        'class hooks render through distinct subclass instances');

    local @Local::ConcurrentPages::PAGE_IDS;
    my $pages = Local::ConcurrentPages->new(as => 'auto');
    my $html_scope = http_scope(headers => [['Accept' => 'text/html']]);
    my $text_scope = http_scope(headers => [['Accept' => 'text/plain']]);
    my $html_response = $pages->not_found($html_scope);
    my $text_response = $pages->not_found($text_scope);
    my (@html_events, @text_events);
    my $html_gate = Future->new;
    my $text_gate = Future->new;
    my $html_calls = 0;
    my $text_calls = 0;
    my $html_send = sub {
        push @html_events, $_[0];
        return ++$html_calls == 1 ? $html_gate : Future->done;
    };
    my $text_send = sub {
        push @text_events, $_[0];
        return ++$text_calls == 1 ? $text_gate : Future->done;
    };

    my $html_future = Future->wrap($html_response->respond(
        $html_scope, sub { Future->done }, $html_send,
    ));
    my $text_future = Future->wrap($text_response->respond(
        $text_scope, sub { Future->done }, $text_send,
    ));
    ok(!$html_future->is_ready && !$text_future->is_ready,
        'both concrete Responses remain independently in flight');

    $text_gate->done;
    $text_future->get;
    ok(!$html_future->is_ready, 'releasing text first does not release HTML');
    $html_gate->done;
    $html_future->get;

    is(response_header(\@html_events, 'Content-Type'),
        'text/html; charset=utf-8', 'HTML response retains its representation');
    is(response_header(\@text_events, 'Content-Type'),
        'text/plain; charset=utf-8', 'text response retains its representation');
    isnt(refaddr($Local::ConcurrentPages::PAGE_IDS[0]),
        refaddr($Local::ConcurrentPages::PAGE_IDS[1]),
        'concurrent hooks receive distinct request-local descriptors');
};

done_testing;
