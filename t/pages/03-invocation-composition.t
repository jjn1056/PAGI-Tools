use strict;
use warnings;

use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use PAGI::Compose qw(compose);
use PAGI::Context;
use PAGI::Pages;
use PAGI::Pages::_Catalog;
use PAGI::Routing qw(route mount);

sub http_scope {
    my (%args) = @_;
    return {
        type         => 'http',
        method       => $args{method} || 'GET',
        path         => defined $args{path} ? $args{path} : '/',
        headers      => $args{headers} || [],
        http_version => '1.1',
        query_string => '',
    };
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
    isa_ok($one, ['PAGI::Response']);
    isa_ok($two, ['PAGI::Response']);
};

subtest 'immediate and deferred invocation preserve response ownership' => sub {
    my $scope = http_scope();
    my @events;
    my $send = sub { push @events, $_[0]; return Future->done };
    my $ctx = PAGI::Context->new($scope, sub { Future->done }, $send);

    my $response = PAGI::Pages->not_found($ctx, as => 'text');
    isa_ok($response, ['PAGI::Response']);
    is(\@events, [], 'immediate Context form is unsent');
    is($response->status, 404, 'immediate Context response has the named status');

    my $scope_response = PAGI::Pages->welcome($scope, as => 'text');
    isa_ok($scope_response, ['PAGI::Response']);
    is($scope_response->status, 200, 'immediate scope welcome has status 200');
    is(\@events, [], 'immediate scope form is unsent');

    my $endpoint = PAGI::Pages->not_found(as => 'text');
    is(ref($endpoint), 'CODE', 'deferred endpoint is a plain coderef');
    ok(!ref($endpoint) || !eval { $endpoint->can('to_app') },
        'deferred endpoint is not a Pages endpoint object');
    isa_ok($endpoint->($ctx, bless({}, 'Local::Snapshot')), ['PAGI::Response']);
    isa_ok($endpoint->($scope), ['PAGI::Response']);
    is(\@events, [], 'deferred Context and scope-only forms remain unsent');

    Future->wrap($endpoint->($scope, sub { Future->done }, $send))->get;
    is($events[0]{status}, 404, 'native triplet sends the page');
    is([map { $_->{type} } @events],
        [qw(http.response.start http.response.body)],
        'native triplet sends one complete buffered response');
};

subtest 'class calls are fresh and retain subclass class dispatch' => sub {
    local $Local::CountingPages::NEW_COUNT = 0;
    local @Local::CountingPages::RENDERED_BY;

    my $first = Local::CountingPages->not_found(http_scope(), as => 'text');
    my $second = Local::CountingPages->not_found(http_scope(), as => 'text');
    isa_ok($first, ['PAGI::Response']);
    isa_ok($second, ['PAGI::Response']);
    is($Local::CountingPages::NEW_COUNT, 2,
        'each subclass class call constructs a fresh subclass instance');
    isnt(refaddr($Local::CountingPages::RENDERED_BY[0]),
        refaddr($Local::CountingPages::RENDERED_BY[1]),
        'each class call renders through its distinct subclass instance');

    my $instance = Local::CountingPages->new(as => 'text');
    my $identity = refaddr($instance);
    local @Local::CountingPages::RENDERED_BY;
    $instance->welcome(http_scope());
    is(refaddr($Local::CountingPages::RENDERED_BY[0]), $identity,
        'instance invocation retains instance identity for hooks');
};

subtest 'scope and channel validation is explicit' => sub {
    my $endpoint = PAGI::Pages->not_found(as => 'text');
    my $http = http_scope();
    my $receive = sub { Future->done };
    my $send = sub { Future->done };

    like(dies { PAGI::Pages->not_found({}) }, qr/scope type is required/,
        'missing immediate scope type is rejected');
    like(dies { PAGI::Pages->not_found({ type => [] }) }, qr/scope type is required/,
        'reference immediate scope type is rejected');
    like(dies { PAGI::Pages->not_found({ type => 'websocket' }) },
        qr/requires HTTP scope.*websocket/, 'non-HTTP immediate scope is rejected');

    like(dies { $endpoint->() }, qr/invalid PAGI::Pages endpoint invocation/,
        'empty endpoint call is rejected');
    like(dies { $endpoint->($http, $receive) },
        qr/invalid PAGI::Pages endpoint invocation/, 'two-channel call is rejected');
    like(dies { $endpoint->($http, [], $send) },
        qr/invalid PAGI::Pages endpoint invocation/, 'non-coderef receive is rejected');
    like(dies { $endpoint->($http, $receive, {}) },
        qr/invalid PAGI::Pages endpoint invocation/, 'non-coderef send is rejected');
    like(dies { $endpoint->($http, $receive, $send, 'extra') },
        qr/invalid PAGI::Pages endpoint invocation/, 'four-channel call is rejected');
    like(dies { $endpoint->({}) }, qr/scope type is required/,
        'missing deferred scope type has the explicit type diagnostic');
    like(dies { $endpoint->({ type => 'sse' }) }, qr/requires HTTP scope.*sse/,
        'non-HTTP deferred scope has the explicit type diagnostic');
    like(dies { $endpoint->([]) }, qr/invalid PAGI::Pages endpoint invocation/,
        'non-scope reference is rejected');

    my $warning = '';
    my $custom;
    {
        local $SIG{__WARN__} = sub { $warning .= $_[0] };
        $custom = PAGI::Context->new(
            { type => 'example.custom', marker => 1 }, $receive, $send,
        );
    }
    isa_ok($custom, ['PAGI::Context']);
    ok(!$custom->can('response'), 'generic custom Context has no HTTP helpers');
    like(dies { PAGI::Pages->not_found($custom) },
        qr/requires HTTP scope.*example\.custom/,
        'generic custom-protocol Context is rejected explicitly');
    like(dies { $endpoint->($custom) },
        qr/requires HTTP scope.*example\.custom/,
        'deferred endpoint also rejects a generic custom Context explicitly');
};

subtest 'page calls validate options and status recipes before capture' => sub {
    like(dies { PAGI::Pages->not_found(unknown => 1) },
        qr/unknown PAGI::Pages error option/, 'unknown option fails before endpoint creation');
    like(dies { PAGI::Pages->welcome(detail => 'not configurable') },
        qr/unknown PAGI::Pages welcome option/, 'welcome accepts only its documented options');
    like(dies { PAGI::Pages->not_found('as') }, qr/key\/value pairs/,
        'odd method option list is rejected');

    for my $bad (399, 600, 'five hundred', []) {
        like(dies { PAGI::Pages->status($bad) }, qr/status must be an integer from 400 to 599/,
            'invalid status is rejected before capture');
    }
    like(dies { PAGI::Pages->status(http_scope(), {}) },
        qr/status must be an integer from 400 to 599/,
        'a reference status after an explicit scope is rejected');
    like(dies { PAGI::Pages->status(599, detail => 'missing semantics') },
        qr/custom status 599 requires type, title, and detail/,
        'unknown status requires explicit semantics');

    my $custom = PAGI::Pages->status(
        http_scope(), 599,
        type => 'https://example.test/problems/upstream-timeout',
        title => 'Upstream Timeout',
        detail => 'The upstream did not answer.',
        as => 'text',
    );
    is($custom->status, 599, 'strict valid custom status returns a Response');

    for my $method (@{PAGI::Pages::_Catalog->_named_methods}) {
        ok(PAGI::Pages->can($method), "$method is an ordinary installed method");
    }
    ok(!PAGI::Pages->can('not_foud'), 'a typo is not dynamically recovered');
    like(dies { PAGI::Pages->not_foud }, qr/Can't locate object method/,
        'a typo fails as an ordinary missing method');
};

subtest 'one endpoint composes as Route, Mount, Compose, and a raw app' => sub {
    my $endpoint = PAGI::Pages->not_found(as => 'text');

    my $route_app = route('/terminal' => $endpoint)->to_app;
    is(run_app($route_app, http_scope(path => '/terminal'))->[0]{status}, 404,
        'Route invokes the endpoint as a Context handler');
    is(run_app($route_app, http_scope(path => '/terminal/child')), [],
        'Route does not own descendant paths');

    my $mount_app = mount('/terminal' => $endpoint)->to_app;
    is(run_app($mount_app, http_scope(path => '/terminal'))->[0]{status}, 404,
        'Mount invokes the endpoint as an opaque app');
    is(run_app($mount_app, http_scope(path => '/terminal/child'))->[0]{status}, 404,
        'Mount owns the complete descendant subtree');

    my $composed = compose(app => $endpoint)->to_app;
    is(run_app($composed, http_scope(path => '/anywhere'))->[0]{status}, 404,
        'Compose invokes the endpoint as its native target');
    is(run_app($endpoint, http_scope(path => '/raw'))->[0]{status}, 404,
        'direct native triplet invocation sends the page');

    my @direct_events;
    my $direct_send = sub { push @direct_events, $_[0]; return Future->done };
    like(dies {
        $endpoint->({ type => 'lifespan' }, sub { Future->done }, $direct_send)
    }, qr/requires HTTP scope.*lifespan/,
        'direct lifespan invocation is rejected synchronously');
    is(\@direct_events, [], 'direct lifespan rejection emits no HTTP events');

    my @lifespan_input = (
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    );
    my $lifespan = run_app(
        $composed,
        { type => 'lifespan' },
        sub { return Future->done(shift @lifespan_input) },
    );
    is($lifespan, [
        { type => 'lifespan.startup.complete' },
        { type => 'lifespan.shutdown.complete' },
    ], 'Compose owns server-root lifespan startup and shutdown');
};

subtest 'outer composition owns HEAD suppression without rewriting dispatch' => sub {
    my $endpoint = PAGI::Pages->not_found(as => 'text');
    my $head_scope = http_scope(method => 'HEAD');
    my $raw = run_app($endpoint, $head_scope);
    ok(length($raw->[1]{body}), 'direct raw invocation preserves the HEAD representation body');

    my $composed = compose(app => $endpoint)->to_app;
    my $head = run_app($composed, http_scope(method => 'HEAD'));
    is($head->[1]{body}, '', 'Compose outer boundary suppresses the final HEAD body');
    is(response_header($head, 'Content-Length'), length($raw->[1]{body}),
        'Compose preserves GET-equivalent Content-Length for HEAD');

    my $custom = compose(routes => [
        route('/custom' => PAGI::Pages->not_found(as => 'text'), methods => ['HEAD']),
        route('/custom' => PAGI::Pages->welcome(as => 'text'), methods => ['GET']),
    ])->to_app;
    my $custom_head = run_app($custom, http_scope(method => 'HEAD', path => '/custom'));
    my $custom_get = run_app($custom, http_scope(method => 'GET', path => '/custom'));
    is($custom_head->[0]{status}, 404, 'custom HEAD route is selected without method rewriting');
    is($custom_head->[1]{body}, '', 'custom HEAD route body is suppressed at the wire edge');
    is($custom_get->[0]{status}, 200, 'the distinct GET route remains independently reachable');
};

subtest 'compiled endpoint is safe across concurrent in-flight calls' => sub {
    local @Local::ConcurrentPages::PAGE_IDS;
    my $endpoint = Local::ConcurrentPages->new(as => 'auto')->not_found;
    my $html_scope = http_scope(headers => [['Accept' => 'text/html']]);
    my $text_scope = http_scope(headers => [['Accept' => 'text/plain']]);
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

    my $html_future = Future->wrap(
        $endpoint->($html_scope, sub { Future->done }, $html_send));
    my $text_future = Future->wrap(
        $endpoint->($text_scope, sub { Future->done }, $text_send));
    ok(!$html_future->is_ready && !$text_future->is_ready,
        'both sends are independently held in flight');

    $text_gate->done;
    $text_future->get;
    ok(!$html_future->is_ready, 'releasing text first does not release HTML');
    $html_gate->done;
    $html_future->get;

    is(response_header(\@html_events, 'Content-Type'), 'text/html; charset=utf-8',
        'HTML request retains its negotiated representation');
    is(response_header(\@text_events, 'Content-Type'), 'text/plain; charset=utf-8',
        'text request retains its negotiated representation');
    like($html_events[1]{body}, qr/<!doctype html>/i, 'HTML body does not leak text rendering');
    unlike($text_events[1]{body}, qr/<!doctype html>/i, 'text body does not leak HTML rendering');
    isnt(refaddr($Local::ConcurrentPages::PAGE_IDS[0]),
        refaddr($Local::ConcurrentPages::PAGE_IDS[1]),
        'concurrent hooks receive distinct request-local descriptors');
};

done_testing;
