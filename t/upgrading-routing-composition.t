#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';

use PAGI::App::Router;
use PAGI::Compose qw(compose);
use PAGI::Response::Text ();
use PAGI::Routing qw(middleware mount route router);
use PAGI::Utils qw(as_app);

{
    package Local::UpgradeEndpoint;
    use parent 'PAGI::Endpoint::Router';

    sub routes {
        my ($self, $r) = @_;
        $r->http_default($self->app_as('not_found_app'));
        $r->mount('/child', routes => sub {
            my ($child) = @_;
            $child->get('/' => sub { return PAGI::Response::Text->new('endpoint child') });
        })->name('child');
    }

    sub not_found_app {
        my ($self, $scope, $receive, $send) = @_;
        return main::response_app(404, 'endpoint missing')->(
            $scope, $receive, $send,
        );
    }
}

sub http_scope {
    my (%changes) = @_;
    my $path = exists $changes{path} ? $changes{path} : '/';
    return {
        type         => 'http',
        http_version => '1.1',
        method       => 'GET',
        scheme       => 'http',
        path         => $path,
        raw_path     => $path,
        root_path    => '',
        query_string => '',
        headers      => [],
        server       => ['testserver', 80],
        client       => ['127.0.0.1', 50000],
        %changes,
    };
}

sub receive_request {
    return Future->done({
        type => 'http.request',
        body => '',
        more => 0,
    });
}

sub run_http {
    my ($app, %changes) = @_;
    my (@events, @warnings);
    my $error;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $ok = eval {
            Future->wrap($app->(
                http_scope(%changes),
                \&receive_request,
                $send,
            ))->get;
            1;
        };
        $error = $@ unless $ok;
    }
    return (\@events, $error, \@warnings);
}

sub response_start {
    my ($events) = @_;
    return (grep {
        ($_->{type} // '') eq 'http.response.start'
    } @$events)[0];
}

sub response_status {
    my ($events) = @_;
    my $start = response_start($events);
    return defined $start ? $start->{status} : undef;
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

sub response_header {
    my ($events, $name) = @_;
    my $start = response_start($events);
    return unless $start;
    for my $header (@{$start->{headers} || []}) {
        return $header->[1]
            if lc($header->[0] // '') eq lc($name);
    }
    return;
}

sub response_app {
    my ($status, $body) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        await Future->wrap($send->({
            type => 'http.response.start', status => $status, headers => [],
        }));
        await Future->wrap($send->({
            type => 'http.response.body', body => $body, more => 0,
        }));
    };
}

sub slurp_file {
    my ($file) = @_;
    open my $handle, '<', $file or die "Cannot read $file: $!";
    local $/;
    my $source = <$handle>;
    close $handle or die "Cannot close $file: $!";
    return $source;
}

subtest 'executable routing-composition migration matrix' => sub {
    my $native = response_app(200, 'native');

    ok(lives { mount('/current', app => $native) },
        'functional Mount accepts a named application');
    my $functional_mount;
    ok(lives {
        $functional_mount = mount('/functional', routes => [
            route('/' => sub { return PAGI::Response::Text->new('functional child') }),
        ]);
    }, 'functional Mount accepts a structural route list');
    my ($functional_events, $functional_error) = run_http(
        router(routes => [$functional_mount])->to_app,
        path => '/functional', raw_path => '/functional',
    );
    is($functional_error, undef,
        'functional routes array constructs and dispatches');
    is(response_body($functional_events), 'functional child',
        'functional Mount routes array reaches its child root');
    ok(lives { middleware('RequestId', header => 'X-Request-ID') },
        'middleware package strings retain their explicit loading contract');

    like(dies { mount('/legacy' => $native) },
        qr/mount option list must be key\/value pairs|unknown mount option/,
        'the positional Mount before-form is executable and rejected');
    like(dies { mount('/legacy', router => router(routes => [])) },
        qr/unknown mount option 'router'/,
        'the router-option before-form is executable and rejected');
    like(dies { mount('/legacy', app => 'Local::LegacyApp') },
        qr/mount app must be a coderef or instantiated object with to_app/,
        'the package-name application before-form is executable and rejected');

    my $callback_calls = 0;
    my $mutable = PAGI::App::Router->new;
    ok(lives {
        $mutable->mount('/mutable', routes => sub {
            my ($child) = @_;
            ++$callback_calls;
            $child->get('/' => sub { return PAGI::Response::Text->new('mutable child') });
            return 'ignored';
        })->name('mutable');
    }, 'mutable Mount routes callback is accepted');
    is($callback_calls, 1,
        'mutable callback runs once during declaration and receives its child');
    my ($mutable_events, $mutable_error) = run_http(
        $mutable->to_app, path => '/mutable', raw_path => '/mutable',
    );
    is($mutable_error, undef, 'mutable callback child constructs and dispatches');
    is(response_body($mutable_events), 'mutable child',
        'the exact Mount spelling normalizes to the child root');

    my $endpoint = Local::UpgradeEndpoint->new;
    ok(lives { $endpoint->to_router },
        'Endpoint routes callback and app_as default construct');
    my ($endpoint_child, $endpoint_child_error) = run_http(
        $endpoint->to_app, path => '/child/', raw_path => '/child/',
    );
    is($endpoint_child_error, undef, 'Endpoint callback child dispatches');
    is(response_body($endpoint_child), 'endpoint child',
        'Endpoint callback stays bound to the same Endpoint object');
    my ($endpoint_missing, $endpoint_missing_error) = run_http(
        $endpoint->to_app, path => '/missing', raw_path => '/missing',
    );
    is($endpoint_missing_error, undef, 'Endpoint app_as HTTP default dispatches');
    is([response_status($endpoint_missing), response_body($endpoint_missing)],
        [404, 'endpoint missing'], 'app_as supplies a native application');
};

subtest 'Route application and Mount positions preserve different ownership' => sub {
    my @seen;
    my $capture = sub {
        my ($kind) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            push @seen, [$kind, $scope->{path}, $scope->{root_path}];
            await Future->wrap(response_app(200, $kind)->(@_));
        };
    };
    my $app = router(routes => [
        route('/exact' => as_app($capture->('route'))),
        mount('/prefix', app => $capture->('mount')),
        mount('/normalized', routes => [
            route('/' => sub { return PAGI::Response::Text->new('normalized') }),
        ]),
    ])->to_app;

    for my $path ('/normalized', '/normalized/') {
        my ($events, $error) = run_http(
            $app, path => $path, raw_path => $path,
        );
        is($error, undef, "$path reaches the constructed child Router");
        is(response_body($events), 'normalized',
            "$path selects the same child root leaf");
    }

    run_http($app, path => '/exact', raw_path => '/exact');
    run_http($app, path => '/prefix/tail', raw_path => '/prefix/tail');
    is(\@seen, [
        ['route', '/exact', ''],
        ['mount', '/tail', '/prefix'],
    ], 'Route keeps an exact leaf while Mount consumes and records its prefix');
};

subtest 'public documentation publishes one final routing model' => sub {
    my $lead = qr/Route\s+matches\s+a\s+complete\s+URL\s+leaf\.\s+Mount\s+composes\s+an\s+application\s+under\s+a\s+prefix\.\s+Router\s+selects\s+and\s+owns\s+routing\s+outcomes\.\s+Middleware\s+wraps\s+behavior\.\s+Compose\s+owns\s+the\s+application\s+root\s+and\s+lifespan\./s;
    for my $file (
        'README.md',
        'lib/PAGI/Tools.pm',
        'lib/PAGI/Tools/Tutorial.pod',
        'lib/PAGI/Tools/Cookbook.pod',
        'lib/PAGI/Routing.pm',
    ) {
        like(slurp_file($file), $lead, "$file leads with the five-part model");
    }

    my $callable_mapping = qr{
        Route\s+CODE\s+endpoint.*?one\s+(?:Request/WebSocket/SSE|Request,
            \s*WebSocket,\s*or\s*SSE).*?
        Route\s+to_app\s+object.*?native\s+PAGI\s+application.*?
        Mount/default\s+CODE.*?native\s+PAGI\s+application.*?
        handler\s+result.*?native\s+CODE.*?instantiated\s+to_app\s+object
    }six;
    for my $file (
        'README.md',
        'UPGRADING.md',
        'lib/PAGI/Routing.pm',
        'lib/PAGI/Tools/Tutorial.pod',
        'lib/PAGI/Tools/Cookbook.pod',
    ) {
        like(slurp_file($file), $callable_mapping,
            "$file publishes the complete callable mapping");
    }

    my @live_docs = (
        'README.md',
        'lib/PAGI/Tools.pm',
        'lib/PAGI/Tools/Tutorial.pod',
        'lib/PAGI/Tools/Cookbook.pod',
        'lib/PAGI/Routing.pm',
        'lib/PAGI/Routing/Mount.pm',
        'lib/PAGI/Routing/Router.pm',
        'lib/PAGI/Routing/Compiler.pm',
        'lib/PAGI/Compose.pm',
        'lib/PAGI/App/Router.pm',
        'lib/PAGI/Endpoint/Router.pm',
        'lib/PAGI/App/Cascade.pm',
        'lib/PAGI/App/File.pm',
        'lib/PAGI/App/URLMap.pm',
        'lib/PAGI/Middleware/ErrorHandler.pm',
        'lib/PAGI/Pages.pm',
        'lib/PAGI/Response.pm',
        'examples/README.md',
        'examples/10-chat-showcase/README.md',
    );
    my $retired_live_api = qr/PAGI::Routing::Trace|pagi\.routing\.trace|PAGI::Middleware::Routing::(?:NotFound|MethodNotAllowed)|mount\('\/[^']*'\s*=>\s*\$|\bgroup\s*\(/;
    my $stale_compose_ownership = qr{
        \bRouter\s+retained\s+by\s+Compose\b
        |
        \bsnapshot\b.{0,80}\bPAGI::Compose\b.{0,20}\broot\s+retains\b
    }isx;
    my %classified_non_routing_api = (
        'lib/PAGI/Tools/Tutorial.pod' => [
            qr/\$urlmap->mount\('\/(?:api|admin|static)' =>/,
        ],
        'lib/PAGI/Routing/Router.pm' => [
            qr/PAGI::Routing::Resolver->new\(router => \$self\)/,
        ],
        'lib/PAGI/Routing/Compiler.pm' => [
            qr/inspectable_router => blessed\(\$node->app\)/,
        ],
        'lib/PAGI/App/Router.pm' => [
            qr/There is no positional Mount target, C<< router => >> form, or C<group>/,
        ],
        'lib/PAGI/App/URLMap.pm' => [
            qr/\$map->mount\('\/(?:api|static)'\s*=>/,
        ],
    );
    for my $file (@live_docs) {
        my @unclassified;
        for my $line (split /\n/, slurp_file($file)) {
            next unless $line =~ $retired_live_api;
            my $allowed = 0;
            for my $pattern (@{$classified_non_routing_api{$file} || []}) {
                $allowed = 1 if $line =~ $pattern;
            }
            push @unclassified, $line unless $allowed;
        }
        is(\@unclassified, [],
            "$file has no unclassified retired routing API");
        unlike(slurp_file($file), $stale_compose_ownership,
            "$file does not assign child Router retention to Compose");
    }

    my $upgrading = slurp_file('UPGRADING.md');
    like($upgrading, qr/^## Routing composition redesign$/m,
        'upgrade guide has one complete routing-composition section');
    for my $replacement (
        'mount(\'/x\', app => $app)',
        'mount(\'/x\', routes => [',
        '$r->mount(\'/x\', routes => sub',
        'Router `http_default`',
        'Compose',
        'package-name application',
        'OpenAPI and schema support remain deferred',
    ) {
        like($upgrading, qr/\Q$replacement\E/,
            "upgrade guide covers $replacement");
    }

    for my $migration (
        qr{Fold a small declarative Router.*?Before:.*?compose\(router => \$routing\).*?After:.*?compose\(.*?routes\s+=> \[.*?route\(}s,
        qr{Preserve a reusable immutable Router.*?Before:.*?compose\(router => \$routing\).*?After:.*?compose\(routes => \[mount\('/' => app => \$routing\)\]\)}s,
        qr{Preserve a PAGI::App::Router snapshot.*?Before:.*?compose\(router => \$builder->to_router\).*?After:.*?\$snapshot = \$builder->to_router.*?compose\(routes => \[mount\('/' => app => \$snapshot\)\]\)}s,
        qr{Preserve a PAGI::Endpoint::Router snapshot.*?Before:.*?compose\(router => \$endpoint->to_router\).*?After:.*?\$snapshot = \$endpoint->to_router.*?compose\(routes => \[mount\('/' => app => \$snapshot\)\]\)}s,
        qr{Deploy a bare Router directly.*?Before:.*?compose\(router => \$routing\)->to_app.*?After:.*?\$routing->to_app}s,
        qr{Flatten direct child nodes deliberately.*?Before:.*?compose\(router => \$routing\).*?After:.*?compose\(routes => \$routing->routes\)}s,
    ) {
        like($upgrading, $migration,
            'upgrade guide publishes one complete Compose migration recipe');
    }
    like($upgrading,
        qr/\$routing->routes.*?flatten.*?discard.*?middleware.*?http_default.*?desc.*?identity.*?Resolver/is,
        'upgrade guide identifies every discarded Router policy and identity');
    like($upgrading,
        qr/API is unreleased.*?no compatibility layer/is,
        'upgrade guide explains why the removed constructor has no compatibility layer');
    like($upgrading,
        qr/\$builder_app\s*=\s*compose\(\s*routes\s*=>\s*\[mount\('\/'\s*=>\s*app\s*=>\s*\$builder\)\],\s*\)->to_app/s,
        'upgrade guide deploys the ordinary App Router frontend directly');
    like($upgrading,
        qr/\$endpoint_app\s*=\s*compose\(\s*routes\s*=>\s*\[mount\('\/'\s*=>\s*app\s*=>\s*\$endpoint\)\],\s*\)->to_app/s,
        'upgrade guide deploys the ordinary Endpoint frontend directly');
    unlike($upgrading,
        qr/\$(?:builder|endpoint)_snapshot\s*=/,
        'upgrade guide does not create unconsumed frontend snapshots');
    like($upgrading,
        qr/\$r->mount\('\/users', app => \$users\)->name\('users'\);/,
        'upgrade guide mounts the ordinary Users Endpoint directly');
    like($upgrading,
        qr/\$r->mount\('\/admin', app => \$admin\)->name\('admin'\);/,
        'upgrade guide mounts the ordinary Admin Endpoint directly');
    unlike($upgrading,
        qr{\$r->mount\('/(?:users|admin)', app => \$(?:users|admin)->to_router\)},
        'upgrade guide reserves nested Endpoint snapshots for a real consumer');

    my $compose_pod = slurp_file('lib/PAGI/Compose.pm');
    like($compose_pod,
        qr/use PAGI::Compose qw\(compose\);.*?routes\s+=> \[.*?route\('\/' => \\&home\).*?mount\('\/api', routes => \\\@api_routes\).*?\].*?http_default => not_found\(\.\.\.\).*?middleware\s+=> \[middleware\('RequestId'\)\].*?lifespan\s+=> \{ startup => \\&startup, shutdown => \\&shutdown \}.*?desc\s+=> 'Application root'/s,
        'Compose synopsis publishes the canonical routes-only grammar');
    like($compose_pod,
        qr/accepted\s+top-level\s+keys\s+are\s+C<routes>,\s+C<http_default>,\s+C<desc>,\s+C<middleware>,\s+and\s+C<lifespan>/,
        'Compose documents every routes-only constructor key');
    like($compose_pod,
        qr/C<router>\s+returns\s+only\s+the\s+distinct\s+root\s+Router\s+constructed\s+and\s+owned\s+by\s+Compose.*?C<routes>\s+returns\s+that\s+root\s+Router's\s+direct\s+children.*?root\s+Mount\s+rather\s+than.*?flattened\s+leaves.*?C<http_default>.*?C<desc>.*?C<named_routes>.*?C<route_named>.*?C<path_for>.*?C<middleware>.*?C<lifespan>/s,
        'Compose documents root ownership, direct-child inspection, and all accessors');
    unlike($compose_pod, qr/^=head2 app$/m,
        'Compose no longer documents an app constructor key');
    unlike($compose_pod, qr/^=head2 router$/m,
        'Compose no longer documents a router constructor key');

    my $four_way = qr{
        compose\(routes\s*=>\s*\\\@nodes\).*?
        compose\(routes\s*=>\s*\[mount\('/'\s*=>\s*app\s*=>\s*\$router\)\]\).*?
        compose\(routes\s*=>\s*\$router->routes\).*?
        \$router->to_app
    }six;
    for my $file ('lib/PAGI/Compose.pm', 'lib/PAGI/Routing/Mount.pm') {
        like(slurp_file($file), $four_way,
            "$file publishes the four-way composition comparison");
    }
    like($compose_pod,
        qr/root\s+Mount\s+consumes\s+no\s+path.*?unnamed\s+Mount\s+adds\s+no\s+namespace.*?child\s+Router\s+owns.*?404.*?405.*?protocol\s+misses.*?later\s+root\s+siblings\s+cannot\s+win/is,
        'Compose documents root Mount matching and outcome ownership');

    my $router_pod = slurp_file('lib/PAGI/Routing/Router.pm');
    like($router_pod,
        qr/compose\(routes => \[mount\('\/' => app => \$router\)\]\).*?Mount\s+retains.*?Router\s+identity.*?Compose.*?distinct\s+outer\s+root\s+Router/is,
        'Router documents explicit preservation beneath a distinct Compose root');
    my $routing_pod = slurp_file('lib/PAGI/Routing.pm');
    like($routing_pod,
        qr/compose\(routes => \[mount\('\/' => app => \$routing\)\]\).*?identity.*?distinct outer root Router/is,
        'Routing documents explicit preservation beneath a distinct Compose root');
    like($compose_pod,
        qr/Starlette.*?does not subclass.*?self\.router.*?lifespan.*?Router.*?mounted.*?do not receive.*?lifespan.*?bare PAGI Router.*?declines lifespan.*?strict mode.*?rejects/is,
        'Compose documents the accurate Starlette lifespan comparison');
    for my $url (
        'https://github.com/Kludex/starlette/blob/main/starlette/applications.py',
        'https://github.com/Kludex/starlette/blob/main/starlette/routing.py',
        'https://github.com/Kludex/starlette/blob/main/tests/test_routing.py',
    ) {
        like($compose_pod, qr/\Q$url\E/,
            "Compose links to official Starlette source $url");
    }

    my $app_router_pod = slurp_file('lib/PAGI/App/Router.pm');
    like($app_router_pod,
        qr/mount\('\/' => app => \$r\).*?ordinary.*?application/is,
        'App Router leads with direct frontend mounting');
    like($app_router_pod,
        qr/to_router.*?parent.*?(?:inspect|discover).*?descendant/is,
        'App Router reserves to_router for structural discovery');

    my $endpoint_router_pod = slurp_file('lib/PAGI/Endpoint/Router.pm');
    like($endpoint_router_pod,
        qr/mount\('\/' => app => \$endpoint\).*?ordinary.*?application/is,
        'Endpoint Router leads with direct frontend mounting');
    like($endpoint_router_pod,
        qr/to_router.*?parent.*?(?:inspect|discover).*?descendant/is,
        'Endpoint Router reserves to_router for structural discovery');

    for my $file (
        'examples/background-tasks/README.md',
        'examples/endpoint-demo/README.md',
        'examples/full-demo/README.md',
        'examples/10-chat-showcase/README.md',
    ) {
        my $source = slurp_file($file);
        unlike($source, qr/\$router->routes/,
            "$file never teaches routes on the mutable frontend");
        like($source,
            qr{mount\('/'\s*=>\s*app\s*=>\s*\$router\)},
            "$file mounts its frontend application directly");
        unlike($source, qr/\$router->to_router/,
            "$file has no unconsumed root snapshot conversion");
        like($source,
            qr/already implements.*?to_app.*?directly.*?to_router.*?(?:inspect|discover|snapshot)/is,
            "$file explains direct application mounting and explicit inspection");
    }

    my $endpoint_readme = slurp_file('examples/endpoint-router-demo/README.md');
    like($endpoint_readme,
        qr{mount\('/'\s*=>\s*app\s*=>\s*\$main\)},
        'Endpoint Router README mounts Main directly at the root');
    like($endpoint_readme,
        qr{app\s*=>\s*\$self->\{api\}->to_router.*?descendant names remain discoverable}s,
        'Endpoint Router README retains the API snapshot for parent discovery');
    like($endpoint_readme,
        qr{app\s*=>\s*\$self->\{events\}->to_router.*?Events object}s,
        'Endpoint Router README retains the Events snapshot for parent discovery');
    is(() = $endpoint_readme =~ /->to_router/g, 2,
        'Endpoint Router README keeps only the two nested discovery snapshots');

    for my $file (
        'lib/PAGI/Tools/Tutorial.pod',
        'lib/PAGI/Tools/Cookbook.pod',
    ) {
        unlike(slurp_file($file),
            qr/(?<!->)mount\('\/[^']*', routes => sub/,
            "$file does not present a mutable callback as functional Mount syntax");
    }

    my $tutorial = slurp_file('lib/PAGI/Tools/Tutorial.pod');
    my @tutorial_paragraphs = map {
        my $paragraph = $_;
        $paragraph =~ s/\s+/ /g;
        $paragraph;
    } split /\n\s*\n/, $tutorial;
    my ($router_outcome_paragraph) = grep {
        /(?:unanswered Router|If no route answers)/i
    } @tutorial_paragraphs;
    $router_outcome_paragraph //= '';
    unlike($router_outcome_paragraph, qr/sends nothing/i,
        'Tutorial never says an unanswered Router sends nothing');
    unlike($router_outcome_paragraph, qr/Compose.*?404.*?405/i,
        'Tutorial never assigns Router 404 and 405 fallback to Compose');
    like($router_outcome_paragraph,
        qr/If no route answers.*?stock Pages 404.*?C<http_default>.*?PARTIAL.*?built-in Pages 405.*?Compose does not own routing fallback.*?root safety.*?lifespan/i,
        'Tutorial assigns 404 and 405 to Router while Compose owns root safety and lifespan');

    my ($app_pl_paragraph) = grep { /F<app\.pl>/i } @tutorial_paragraphs;
    $app_pl_paragraph //= '';
    unlike($app_pl_paragraph,
        qr/must still be a native coderef/i,
        'Tutorial never restricts app.pl to a native coderef');
    like($app_pl_paragraph,
        qr/F<app\.pl> may return either a native coderef or an instantiated component object with C<to_app>, including a Compose description/i,
        'Tutorial permits either native coderef or instantiated to_app object from app.pl');
    unlike($app_pl_paragraph, qr/routing-capable Cascade/i,
        'Tutorial does not give Cascade special routing semantics');
    like($app_pl_paragraph,
        qr/Cascade is ordinary status-driven application coordination and carries no special Router semantics/i,
        'Tutorial characterizes Cascade as ordinary status-driven coordination');

    my $changes = slurp_file('Changes');
    like($changes, qr/\A# Revision history for PAGI-Tools\s+0\.002003 - UNRELEASED\b/s,
        'release note stays inside unreleased 0.002003');
    like($changes, qr/Route matches a complete URL leaf/,
        'release note records the routing composition redesign');
    like($changes,
        qr/Compose now accepts only `routes`.*?existing Routers.*?Mount.*?\$router->routes.*?flatten/is,
        'release note records routes-only Compose and explicit Router preservation');

    my @application_docs = (
        'README.md', 'Changes', 'lib/PAGI/Tools.pm',
        'lib/PAGI/Routing.pm', 'lib/PAGI/Routing/Route.pm',
        'lib/PAGI/App/Router.pm', 'lib/PAGI/Endpoint/Router.pm',
        'lib/PAGI/Pages.pm', 'lib/PAGI/Compose.pm',
        'lib/PAGI/Middleware/Builder.pm',
        'lib/PAGI/Tools/Tutorial.pod', 'lib/PAGI/Tools/Cookbook.pod',
    );
    for my $file (@application_docs) {
        my $source = slurp_file($file);
        unlike($source,
            qr/\brequest_app\b|\b(?:welcome|status|redirect|not_found|gone|unauthorized|forbidden|method_not_allowed|conflict|too_many_requests|internal_server_error|bad_gateway|service_unavailable)_page\b|\braw\s*=>/,
            "$file contains no retired application-boundary spelling");
    }

    my $route_pod = slurp_file('lib/PAGI/Routing/Route.pm');
    unlike($route_pod, qr/C<raw>|C<target>|C<is_raw>|normal or raw target/i,
        'Route POD has no deferred raw-marker or removed-accessor language');

    my $cookbook = slurp_file('lib/PAGI/Tools/Cookbook.pod');
    unlike($cookbook, qr/C<\/welcome> is an ordinary function handler/,
        'Cookbook identifies the direct welcome() value as an application');
    like($cookbook,
        qr/deliberate mutation after C<to_app>.*caller-owned.*unwise.*valid/is,
        'Cookbook records the approved exact-object mutation gotcha');
};

subtest 'Router http_default replaces application 404 middleware' => sub {
    my $default_calls = 0;
    my $routing = router(
        http_default => async sub {
            my ($scope, $receive, $send) = @_;
            ++$default_calls;
            await Future->wrap(response_app(404, 'custom missing')->(@_));
        },
        routes => [
            route('/items' => sub { return PAGI::Response::Text->new('items') },
                methods => 'GET'),
        ],
    );

    my ($missing, $missing_error) = run_http(
        $routing->to_app, path => '/missing', raw_path => '/missing',
    );
    is($missing_error, undef, 'custom HTTP default completes');
    is([response_status($missing), response_body($missing)],
        [404, 'custom missing'], 'HTTP NONE selects the Router default');
    is($default_calls, 1, 'the custom default runs once');

    my ($method, $method_error) = run_http(
        $routing->to_app,
        method => 'POST', path => '/items', raw_path => '/items',
    );
    is($method_error, undef, 'built-in method outcome completes');
    is(response_status($method), 405,
        'HTTP PARTIAL uses the Router built-in 405');
    is(response_header($method, 'Allow'), 'GET, HEAD',
        'the built-in 405 publishes its exact method union');
    is($default_calls, 1, 'PARTIAL does not invoke the HTTP default');
};

subtest 'nested Router owns its outcomes and Mount app/routes are explicit' => sub {
    my ($child_defaults, $parent_defaults, $later_parent) = (0, 0, 0);
    my $child = router(
        http_default => async sub {
            ++$child_defaults;
            await Future->wrap(response_app(404, 'child missing')->(@_));
        },
        routes => [
            route('/item' => sub { return PAGI::Response::Text->new('child item') },
                methods => 'GET'),
        ],
    );
    my $parent = router(
        http_default => async sub {
            ++$parent_defaults;
            await Future->wrap(response_app(404, 'parent missing')->(@_));
        },
        routes => [
            mount('/child', app => $child),
            mount('/inline', routes => [
                route('/item' => sub { return PAGI::Response::Text->new('inline item') }),
            ]),
            route('/child/missing' => sub {
                ++$later_parent;
                return PAGI::Response::Text->new('later parent');
            }),
        ],
    )->to_app;

    my ($missing, $missing_error) = run_http(
        $parent, path => '/child/missing', raw_path => '/child/missing',
    );
    is($missing_error, undef, 'nested NONE completes at the child');
    is([response_status($missing), response_body($missing)],
        [404, 'child missing'], 'selected child owns its HTTP default');

    my ($method, $method_error) = run_http(
        $parent, method => 'POST', path => '/child/item', raw_path => '/child/item',
    );
    is($method_error, undef, 'nested PARTIAL completes at the child');
    is([response_status($method), response_header($method, 'Allow')],
        [405, 'GET, HEAD'], 'selected child owns its built-in 405');

    my ($inline, $inline_error) = run_http(
        $parent, path => '/inline/item', raw_path => '/inline/item',
    );
    is($inline_error, undef, 'routes shorthand builds a complete child Router');
    is(response_body($inline), 'inline item',
        'Mount routes dispatches through the constructed child');
    is([$child_defaults, $parent_defaults, $later_parent], [1, 0, 0],
        'child outcomes never resume parent routing or parent default policy');
};

subtest 'removed declaration spellings fail instead of aliasing' => sub {
    for my $option ('not_found', 'method_not_allowed') {
        like(
            dies { router(routes => [], $option => sub { return }) },
            qr/unknown router option '\Q$option\E'/,
            "removed Router $option option is unknown",
        );
        like(
            dies { PAGI::App::Router->new($option => sub { return }) },
            qr/unknown router option '\Q$option\E'/,
            "removed App Router $option option is unknown",
        );
    }

    my $native = response_app(200, 'native');
    my $immutable = router(routes => []);
    like(dies { mount('/legacy' => $native) },
        qr/mount option list must be key\/value pairs|unknown mount option/,
        'functional positional Mount target is rejected');
    like(dies { mount('/legacy', router => $immutable) },
        qr/unknown mount option 'router'/,
        'functional router target option is rejected');
    like(dies { PAGI::App::Router->new->mount('/legacy' => $native) },
        qr/mount option list must be key\/value pairs|unknown mount option/,
        'mutable positional Mount target is rejected');
    like(dies {
        PAGI::App::Router->new->mount('/legacy', router => $immutable);
    }, qr/unknown mount option 'router'/,
        'mutable router target option is rejected');

    ok(!PAGI::App::Router->can('group'), 'App Router has no group method');
    ok(!PAGI::Endpoint::Router->can('group'),
        'Endpoint Router facade has no group method');
    my $mount = mount('/current', app => $native);
    ok(!$mount->can('router'), 'Mount has no router accessor');
    ok(!$mount->can('target'), 'Mount has no target accessor');
    ok(!$mount->can('is_raw'), 'Mount has no mode accessor');
};

subtest 'native application positions reject package strings' => sub {
    like(dies { mount('/legacy', app => 'Local::LegacyApp') },
        qr/mount app must be a coderef or instantiated object with to_app/,
        'functional Mount app rejects a package string');
    like(dies { router(routes => [], http_default => 'Local::LegacyApp') },
        qr/router http_default must be a coderef or instantiated object with to_app/,
        'Router HTTP default rejects a package string');
    like(dies {
        PAGI::App::Router->new->mount('/legacy', app => 'Local::LegacyApp');
    }, qr/mount app must be a coderef or instantiated object with to_app/,
        'mutable Mount app rejects a package string');
    like(dies {
        PAGI::App::Router->new->get('/application' => 'Local::LegacyApp');
    }, qr/route endpoint must be a coderef or instantiated object with to_app/,
        'Route application position rejects a package string');
    ok(!$INC{'Local/LegacyApp.pm'}, 'rejection never loads the package');
};

subtest 'direct Router remains low-level and Compose supplies safety' => sub {
    my $routing = router(routes => [
        route('/silent' => as_app(sub { return Future->done })),
    ]);

    my ($direct, $direct_error, $direct_warnings) = run_http(
        $routing->to_app, path => '/silent', raw_path => '/silent',
    );
    is($direct_error, undef, 'direct Router permits selected application silence');
    is([$direct, $direct_warnings], [[], []],
        'direct Router emits neither safety events nor warnings');

    local $ENV{PAGI_ENV} = 'production';
    my ($safe, $safe_error, $safe_warnings) = run_http(
        compose(routes => [mount('/' => app => $routing)])->to_app,
        path => '/silent', raw_path => '/silent',
    );
    is($safe_error, undef, 'Compose contains the before-start failure');
    is(response_status($safe), 500, 'Compose emits its production-safe 500');
    is(scalar @$safe_warnings, 1, 'Compose reports the lifecycle failure once');
};

subtest 'retired routing support modules are not loadable' => sub {
    my @removed = (
        join('::', qw(PAGI Routing Trace)),
        join('::', qw(PAGI Routing Trace Recorder)),
        join('::', qw(PAGI Routing Trace Snapshot)),
        join('::', qw(PAGI Middleware Routing), '_' . 'Fallback'),
        join('::', qw(PAGI Middleware Routing), 'Not' . 'Found'),
        join('::', qw(PAGI Middleware Routing), 'Method' . 'NotAllowed'),
    );
    for my $module (@removed) {
        my $file = $module;
        $file =~ s{::}{/}g;
        $file .= '.pm';
        my $loaded = eval { require $file; 1 };
        ok(!$loaded, "$module was removed instead of deprecated");
    }
};

subtest 'Router and Compose have no retired evidence channel and Context stays absent' => sub {
    my @files = (
        'lib/PAGI/Routing/Router.pm',
        'lib/PAGI/App/Router.pm',
        'lib/PAGI/App/Router/Builder.pm',
        'lib/PAGI/App/Router/Materializer.pm',
        'lib/PAGI/Compose.pm',
        'lib/PAGI/Compose/Compiler.pm',
        'lib/PAGI/Compose/ResponseGuard.pm',
    );
    my @removed_context_files = (
        'lib/PAGI/Context.pm',
        'lib/PAGI/Context/HTTP.pm',
        'lib/PAGI/Context/SSE.pm',
        'lib/PAGI/Context/WebSocket.pm',
    );
    for my $file (@removed_context_files) {
        ok(!-e $file, "$file remains absent with no compatibility source");
    }
    my @retired = (
        join('::', qw(PAGI Routing Trace)),
        join('.', qw(pagi routing trace)),
        join('::', qw(PAGI Middleware Routing), 'Not' . 'Found'),
        join('::', qw(PAGI Middleware Routing), 'Method' . 'NotAllowed'),
        'check' . 'point',
        'attempt' . 's',
        join('_', qw(routing declined)),
    );
    for my $file (@files) {
        open my $handle, '<', $file or die "Cannot read $file: $!";
        local $/;
        my $source = <$handle>;
        close $handle or die "Cannot close $file: $!";
        for my $retired (@retired) {
            unlike($source, qr/\Q$retired\E/,
                "$file does not consume retired routing evidence '$retired'");
        }
    }
};

done_testing;
