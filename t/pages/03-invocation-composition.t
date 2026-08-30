use strict;
use warnings;

use Test2::V0;
use Future;
use JSON::MaybeXS qw(decode_json);
use Scalar::Util qw(refaddr);

use PAGI::Pages;
use PAGI::Pages::_Catalog;
use PAGI::Request;
use PAGI::Routing qw(route mount);
use PAGI::Utils qw(invoke_app);

my @CATALOG_FUNCTIONS = @{PAGI::Pages::_Catalog->_named_methods};
my @COMMON_FUNCTIONS = qw(
    welcome not_found unauthorized forbidden method_not_allowed conflict
    too_many_requests internal_server_error bad_gateway service_unavailable
);
my @ALL_FUNCTIONS = (
    qw(welcome status redirect), @CATALOG_FUNCTIONS,
);

sub http_scope {
    my (%args) = @_;
    my @headers = @{$args{headers} || []};
    push @headers, ['Accept' => $args{accept}] if defined $args{accept};
    return {
        type         => 'http',
        method       => $args{method} || 'GET',
        path         => defined $args{path} ? $args{path} : '/',
        headers      => \@headers,
        http_version => exists($args{http_version})
            ? $args{http_version} : '1.1',
        query_string => exists($args{query_string})
            ? $args{query_string} : '',
    };
}

sub http_request {
    my (%args) = @_;
    return PAGI::Request->new(
        http_scope(%args), sub { Future->done },
    );
}

sub run_app {
    my ($application, $scope, $receive) = @_;
    my @events;
    $receive ||= sub { return Future->done };
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    Future->wrap(invoke_app(
        $application, $scope, $receive, $send,
    ))->get;
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

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
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
    package Local::HookPages;
    our @ISA = ('PAGI::Pages');

    sub render_text {
        my ($self, $page) = @_;
        return "hook:$page->{status}:$page->{title}\n";
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

subtest 'constructor policy and deferred factories are immutable and request-independent' => sub {
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
    my $one = $pages->not_found;
    my $two = $pages->not_found;
    isa_ok($one, ['PAGI::Pages::Application']);
    isa_ok($two, ['PAGI::Pages::Application']);
    isnt(refaddr($one), refaddr($two), 'factory calls create distinct applications');

    $pages->{as} = 'json';
    my $snapshotted = run_app(
        $one, http_scope(accept => 'application/problem+json'),
    );
    is(response_header($snapshotted, 'Content-Type'),
        'text/plain; charset=utf-8',
        'later factory mutation cannot change captured policy');

    my $headers = ['X-Captured' => 'before'];
    my $extensions = { metadata => { token => 'original' } };
    my $captured = PAGI::Pages->not_found(
        as => 'json', headers => $headers, extensions => $extensions,
    );
    $headers->[1] = 'after';
    $extensions->{metadata}{token} = 'after';
    my $events = run_app($captured, http_scope());
    is(response_header($events, 'X-Captured'), 'before',
        'caller header mutation cannot change the application');
    is(decode_json(response_body($events))->{metadata}{token}, 'original',
        'caller extension mutation cannot change the application');
};

subtest 'exports are opt-in and the common and all bundles are exact' => sub {
    is(\@PAGI::Pages::EXPORT, [], 'Pages exports nothing by default');
    is(\@PAGI::Pages::EXPORT_OK, \@ALL_FUNCTIONS,
        'optional exports contain every and only deferred factory');
    is($PAGI::Pages::EXPORT_TAGS{common}, \@COMMON_FUNCTIONS,
        ':common excludes the collision-prone status and redirect names');
    is($PAGI::Pages::EXPORT_TAGS{all}, \@ALL_FUNCTIONS,
        ':all contains every deferred factory');

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
    my $explicit_ok = eval q{
        package Local::ExplicitPageImports;
        PAGI::Pages->import(qw(status redirect));
        1;
    };
    is($explicit_ok, 1, 'status and redirect remain explicitly importable');

    for my $name (@ALL_FUNCTIONS) {
        is(Local::CommonPageImports->can($name) ? 1 : 0,
            (grep { $_ eq $name } @COMMON_FUNCTIONS) ? 1 : 0,
            ":common membership for $name is exact");
        ok(Local::AllPageImports->can($name), ":all exports $name");
    }
    ok(!Local::CommonPageImports->can('status'), ':common does not import status');
    ok(!Local::CommonPageImports->can('redirect'), ':common does not import redirect');
    ok(Local::ExplicitPageImports->can('status'), 'status supports explicit import');
    ok(Local::ExplicitPageImports->can('redirect'), 'redirect supports explicit import');
    ok(!main->can('welcome'), 'plain use PAGI::Pages imports no factory');

    my $old_ok = eval q{
        package Local::RemovedPageImports;
        PAGI::Pages->import(qw(welcome_page not_found_page));
        1;
    };
    ok(!$old_ok, 'removed _page functions cannot be imported');
    like($@, qr/not exported|export/i, 'removed import reports an export error');
    ok(!PAGI::Pages->can('welcome_page'), 'welcome_page is absent from Pages');
    ok(!PAGI::Pages->can('not_found_page'), 'named _page methods are absent');
};

subtest 'class, configured-instance, subclass, and imported factories retain policy' => sub {
    my $class_app = PAGI::Pages->not_found(as => 'text');
    my $pages = PAGI::Pages->new(as => 'text');
    my $instance_app = $pages->not_found;
    my $not_found = Local::AllPageImports->can('not_found');
    my $imported_app = $not_found->(as => 'text');

    for my $case (
        [class => $class_app],
        [instance => $instance_app],
        [imported => $imported_app],
    ) {
        my ($label, $app) = @$case;
        isa_ok($app, ['PAGI::Pages::Application'], "$label form returns an application");
        my $events = run_app($app, http_scope(accept => 'application/problem+json'));
        is($events->[0]{status}, 404, "$label form retains status");
        is(response_header($events, 'Content-Type'), 'text/plain; charset=utf-8',
            "$label form retains fixed representation");
        is(response_body($events),
            "404 Not Found\n\nThe requested resource was not found.\n",
            "$label form renders the same stock body");
    }

    my $subclass = Local::HookPages->not_found(as => 'text');
    is(response_body(run_app($subclass, http_scope())),
        "hook:404:Not Found\n",
        'subclass factory retains its overridable renderer');

    my $status = Local::ExplicitPageImports->can('status');
    is(run_app($status->(410, as => 'text'), http_scope())->[0]{status}, 410,
        'explicit status export is a general deferred factory');
    my $redirect = Local::ExplicitPageImports->can('redirect');
    is(run_app($redirect->('/next', status => 308, as => 'text'),
        http_scope())->[0]{status}, 308,
        'explicit redirect export is a general deferred factory');
};

subtest 'source-first factory forms are rejected without emitting' => sub {
    my $request = http_request();
    my $welcome = Local::AllPageImports->can('welcome');

    like(dies { PAGI::Pages->welcome($request) },
        qr/options|option names|key\/value|source|Request/i,
        'qualified welcome rejects a Request argument');
    like(dies { $welcome->($request) },
        qr/options|option names|key\/value|source|Request/i,
        'imported welcome rejects a Request argument');
    like(dies { PAGI::Pages->not_found(http_scope()) },
        qr/options|option names|key\/value|source|scope/i,
        'qualified named factory rejects a scope argument');
    like(dies { PAGI::Pages->status($request, 410) },
        qr/status|options|option names|key\/value|source|Request/i,
        'status rejects an old source-first call');
    like(dies { PAGI::Pages->redirect($request, '/next') },
        qr/target|options|option names|key\/value|source|Request/i,
        'redirect rejects an old source-first call');

    my @events;
    like(dies {
        PAGI::Pages->welcome(
            http_scope(), sub { Future->done },
            sub { push @events, $_[0]; Future->done },
        );
    }, qr/PAGI::Pages|option|key\/value/i,
        'native triplet cannot be mistaken for factory arguments');
    is(\@events, [], 'rejected source/native calls emit no event');
};

subtest 'deferred Pages applications occupy Route, Mount, and root positions directly' => sub {
    my $route_app = route(
        '/welcome' => PAGI::Pages->welcome(as => 'text'),
    )->to_app;
    my $welcome = run_app($route_app, http_scope(path => '/welcome'));
    is($welcome->[0]{status}, 200, 'a Pages application works directly in Route');
    is(response_header($welcome, 'Content-Type'), 'text/plain; charset=utf-8',
        'Route preserves the Pages representation');

    my $mounted = mount(
        '/missing', app => PAGI::Pages->not_found(as => 'text'),
    )->to_app;
    my $missing = run_app($mounted, http_scope(path => '/missing/child'));
    is($missing->[0]{status}, 404, 'a Pages application works directly in Mount');

    my $root = run_app(PAGI::Pages->welcome(as => 'text'), http_scope());
    is($root->[0]{status}, 200, 'a bare Pages application serves HTTP as a root');
};

subtest 'each invocation negotiates and emits independently without hidden state' => sub {
    local $Local::CountingPages::NEW_COUNT = 0;
    local @Local::CountingPages::RENDERED_BY;
    my $first = Local::CountingPages->not_found(as => 'text');
    my $second = Local::CountingPages->not_found(as => 'text');
    is($Local::CountingPages::NEW_COUNT, 2,
        'each subclass class factory constructs one fresh policy');
    run_app($first, http_scope());
    run_app($second, http_scope());
    isnt(refaddr($Local::CountingPages::RENDERED_BY[0]),
        refaddr($Local::CountingPages::RENDERED_BY[1]),
        'distinct factory applications retain distinct policy snapshots');

    local @Local::ConcurrentPages::PAGE_IDS;
    my $component = Local::ConcurrentPages->new(as => 'auto')->not_found;
    my $app = $component->to_app;
    my $html_scope = http_scope(accept => 'text/html');
    my $text_scope = http_scope(accept => 'text/plain');
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

    my $html_future = Future->wrap($app->(
        $html_scope, sub { Future->done }, $html_send,
    ));
    my $text_future = Future->wrap($app->(
        $text_scope, sub { Future->done }, $text_send,
    ));
    ok(!$html_future->is_ready && !$text_future->is_ready,
        'both request-local Responses can remain independently in flight');

    $text_gate->done;
    $text_future->get;
    ok(!$html_future->is_ready, 'releasing text first does not release HTML');
    $html_gate->done;
    $html_future->get;

    is(response_header(\@html_events, 'Content-Type'),
        'text/html; charset=utf-8', 'HTML invocation retains its representation');
    is(response_header(\@text_events, 'Content-Type'),
        'text/plain; charset=utf-8', 'text invocation retains its representation');
    isnt(refaddr($Local::ConcurrentPages::PAGE_IDS[0]),
        refaddr($Local::ConcurrentPages::PAGE_IDS[1]),
        'concurrent hooks receive distinct request-local descriptors');
};

done_testing;
