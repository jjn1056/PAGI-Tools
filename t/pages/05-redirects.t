use strict;
use warnings;

use Test2::V0;
use Encode qw(decode FB_CROAK);
use Future;
use JSON::MaybeXS qw(decode_json);
use Scalar::Util qw(dualvar);

use PAGI::Pages;
use PAGI::Utils qw(invoke_app);

{
    package Local::HostileRedirectJSONPages;
    our @ISA = ('PAGI::Pages');
    sub render_json {
        return {
            status   => 301,
            location => '/renderer-invented',
            custom   => 'kept',
        };
    }
}

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
        query_string => exists($args{query_string}) ? $args{query_string} : '',
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

sub header {
    my ($events, $name) = @_;
    my $wanted = lc $name;
    for my $pair (@{$events->[0]{headers} || []}) {
        return $pair->[1] if lc($pair->[0]) eq $wanted;
    }
    return;
}

sub body {
    my ($events) = @_;
    return $events->[1]{body};
}

sub decoded_body {
    my ($application, $scope) = @_;
    return decode('UTF-8', body(send_response($application, $scope)), FB_CROAK);
}

subtest 'redirect methods select only their documented statuses' => sub {
    my @cases = (
        [redirect            => [status => 301], 301, 'Moved Permanently'],
        [redirect            => [status => 302], 302, 'Found'],
        [redirect            => [status => 303], 303, 'See Other'],
        [redirect            => [status => 307], 307, 'Temporary Redirect'],
        [redirect            => [status => 308], 308, 'Permanent Redirect'],
        [moved_permanently   => [],              301, 'Moved Permanently'],
        [found               => [],              302, 'Found'],
        [see_other           => [],              303, 'See Other'],
        [temporary_redirect  => [],              307, 'Temporary Redirect'],
        [permanent_redirect  => [],              308, 'Permanent Redirect'],
    );

    for my $case (@cases) {
        my ($method, $options, $status, $title) = @$case;
        my @args = ($method eq 'redirect' ? ('/next', @$options) : ('/next', @$options));
        my $application = PAGI::Pages->$method(@args, as => 'text');
        my $events = send_response($application);
        is($events->[0]{status}, $status, "$method has status $status");
        like(decode('UTF-8', body($events), FB_CROAK), qr/\Q$status $title\E/,
            "$method renders its registered title");
    }

    for my $status (300, 304, 305, 306, 309, 399, '302.0', 'x') {
        like(dies { PAGI::Pages->redirect(
            '/next', status => $status) },
            qr/status.*301.*302.*303.*307.*308/i,
            "generic redirect rejects unsupported status $status");
    }

    for my $case (
        ['canonical string with unsupported numeric facet', dualvar(999, '301')],
        ['supported numeric with noncanonical string facet', dualvar(301, '999')],
    ) {
        my ($label, $status) = @$case;
        like(dies { PAGI::Pages->redirect(
            '/next', status => $status) },
            qr/status.*301.*302.*303.*307.*308/i,
            "generic redirect rejects $label");
    }

    my @supported = qw(301 302 303 307 308);
    for my $string_status (@supported) {
        for my $numeric_status (@supported) {
            next if $numeric_status eq $string_status;
            my $status = dualvar(0 + $numeric_status, $string_status);
            like(dies { PAGI::Pages->redirect(
                '/next', status => $status) },
                qr/status.*301.*302.*303.*307.*308/i,
                "generic redirect rejects string $string_status with numeric "
                    . $numeric_status);
        }
    }

    my $matching = PAGI::Pages->redirect(
        '/next', status => dualvar(307, '307'), as => 'text',
    );
    is(send_response($matching)->[0]{status}, 307,
        'generic redirect stores a matching dualvar as the intended status');

    like(dies { PAGI::Pages->found(
        '/next', status => 302) }, qr/status/i,
        'named redirect rejects a supplied status option even when it matches');
};

subtest 'redirect factories are source-free deferred applications' => sub {
    my $scope = http_scope();
    my @events;

    my $class = PAGI::Pages->redirect('/class', as => 'text');
    isa_ok($class, ['PAGI::Pages::Application']);
    is(header(send_response($class, $scope), 'Location'), '/class',
        'class factory resolves the redirect when invoked');

    my $pages = PAGI::Pages->new(as => 'text');
    my $instance = $pages->found('/instance');
    isa_ok($instance, ['PAGI::Pages::Application']);
    is(header(send_response($instance, $scope), 'Location'), '/instance',
        'configured factory retains its redirect target');

    is(header(send_response(PAGI::Pages->see_other('/endpoint', as => 'text')),
        'Location'), '/endpoint', 'no-source redirect construction is canonical');
    like(dies { PAGI::Pages->redirect($scope, '/old-source', as => 'text') },
        qr/target|option|URI-reference/i,
        'old source-first redirect construction is rejected');
    like(dies {
        PAGI::Pages->see_other(
            $scope, sub { Future->done },
            sub { push @events, $_[0]; Future->done },
        )
    }, qr/PAGI::Pages|option|redirect/i,
        'native three-argument redirect invocation is rejected');
    is(\@events, [], 'redirect construction and rejected native calls emit no events');
};

subtest 'redirect validates its target and options before construction' => sub {
    for my $target ("/bad\nnext", "/wide\x{263a}", {}, []) {
        like(dies { PAGI::Pages->redirect($target) },
            qr/target.*URI-reference/i,
            'redirect rejects control, wide, and reference targets');
    }
    is(header(send_response(PAGI::Pages->redirect(
        'https://example.test/path')), 'Location'),
        'https://example.test/path',
        'absolute target is preserved');
    is(header(send_response(PAGI::Pages->redirect(
        '../relative/path')), 'Location'),
        '../relative/path', 'relative target is preserved');

    like(dies { PAGI::Pages->redirect(
        '/next', type => 'https://example.test') },
        qr/unknown PAGI::Pages redirect option/, 'problem options are not redirect options');
    like(dies { PAGI::Pages->redirect(
        '/next', preserve_query => []) },
        qr/preserve_query.*Boolean/i, 'preserve_query requires a Boolean scalar');
};

subtest 'redirect bodies and Location share the one final target' => sub {
    my $target = q{/next?existing=1&x=<tag>#part};

    my $html = PAGI::Pages->redirect($target, as => 'html');
    my $html_events = send_response($html);
    is(header($html_events, 'Content-Type'), 'text/html; charset=utf-8',
        'fixed HTML redirect creates the concrete HTML representation');
    is(header($html_events, 'Location'), $target, 'HTML Location is the exact target');
    my $html_body = decode('UTF-8', body($html_events), FB_CROAK);
    like($html_body, qr{href="/next\?existing=1&amp;x=&lt;tag&gt;#part"},
        'HTML escapes the target in the href');
    like($html_body, qr{>/next\?existing=1&amp;x=&lt;tag&gt;#part</a>},
        'HTML escapes the target as link text');

    my $text = PAGI::Pages->redirect($target, as => 'text');
    is(decoded_body($text), "302 Found\n\nThe requested resource has moved.\n\nLocation:\n$target\n",
        'text includes the unchanged final target');

    my $json = PAGI::Pages->permanent_redirect($target, as => 'json');
    my $json_events = send_response($json);
    is(header($json_events, 'Content-Type'), 'application/json',
        'redirect JSON is ordinary application/json');
    is(decode_json(body($json_events)), {
        status => 308, location => $target,
        detail => 'The requested resource has moved.',
    }, 'redirect JSON contains the same exact location, not a problem document');

    my $hostile = Local::HostileRedirectJSONPages->permanent_redirect(
        $target, as => 'json',
    );
    is(decode_json(body(send_response($hostile))), {
        status => 308, location => $target, custom => 'kept',
    }, 'base class restores redirect status and Location after render_json');
};

subtest 'redirect query preservation keeps raw data before the first fragment' => sub {
    my @cases = (
        ['/search',                   'q=perl', '/search?q=perl'],
        ['/search?',                  'q=perl', '/search?q=perl'],
        ['/search?sort=date',         'q=perl', '/search?sort=date&q=perl'],
        ['/search#results',           'q=perl', '/search?q=perl#results'],
        ['/search?sort=date#results', 'q=perl', '/search?sort=date&q=perl#results'],
        ['/search#first#second', 'q=a%2Bb&x=%26',
            '/search?q=a%2Bb&x=%26#first#second'],
        ['/search#results',           '',       '/search#results'],
    );

    for my $case (@cases) {
        my ($target, $query, $want) = @$case;
        my $scope = http_scope(query_string => $query);
        my $html = PAGI::Pages->redirect(
            $target, preserve_query => 1, as => 'html',
        );
        my $html_events = send_response($html, $scope);
        is(header($html_events, 'Location'), $want,
            "Location preserves '$target' with '$query'");
        my $html_body = decode('UTF-8', body($html_events), FB_CROAK);
        my $escaped = $want;
        $escaped =~ s/&/&amp;/g;
        $escaped =~ s/</&lt;/g;
        $escaped =~ s/>/&gt;/g;
        $escaped =~ s/"/&quot;/g;
        $escaped =~ s/'/&#39;/g;
        like($html_body, qr{href="\Q$escaped\E"}, 'HTML href describes final target');
        like($html_body, qr{>\Q$escaped\E</a>}, 'HTML text describes final target');

        my $text = PAGI::Pages->redirect($target, preserve_query => 1, as => 'text');
        like(decoded_body($text, $scope), qr/\Q$want\E/, 'text describes final target');

        my $json = PAGI::Pages->redirect($target, preserve_query => 1, as => 'json');
        my $json_data = decode_json(body(send_response($json, $scope)));
        is($json_data->{location}, $want, 'JSON describes final target');
    }

    my $default = PAGI::Pages->redirect(
        '/search#results', as => 'text',
    );
    is(header(send_response($default,
        http_scope(query_string => 'q=perl')), 'Location'), '/search#results',
        'preserve_query defaults to false');
};

subtest 'query preservation rejects unsafe raw query data before response construction' => sub {
    my $safe = PAGI::Pages->redirect(
        '/search#results',
        preserve_query => 1, as => 'text',
    );
    is(header(send_response($safe,
        http_scope(query_string => 'q=a%2Bb&x=%26')), 'Location'),
        '/search?q=a%2Bb&x=%26#results',
        'safe percent-encoded raw query bytes are unchanged');

    for my $query ("q=ok\r\nInjected: yes", "q=ok\x1f", "q=\x{263a}") {
        my $application = PAGI::Pages->redirect(
            '/search', preserve_query => 1, as => 'text',
        );
        like(dies {
            send_response($application, http_scope(query_string => $query));
        }, qr/query_string.*URI-reference/i,
            'unsafe preserved query is rejected before response emission');

    }
};

subtest 'redirect cache and retry fields follow redirect policy' => sub {
    my $default = PAGI::Pages->redirect('/next', as => 'text');
    is(header(send_response($default), 'Cache-Control'), undef,
        'redirects do not add Cache-Control by default');

    my $explicit = PAGI::Pages->redirect(
        '/next', as => 'text', cache_control => 'public, max-age=60',
        retry_after => 30,
    );
    my $explicit_events = send_response($explicit);
    is(header($explicit_events, 'Cache-Control'), 'public, max-age=60',
        'redirect accepts explicit cache policy');
    is(header($explicit_events, 'Retry-After'), '30',
        'redirect accepts Retry-After delay seconds');

    like(dies { PAGI::Pages->redirect(
        '/next', retry_after => 30,
        headers => ['Retry-After' => '60'],
    ) }, qr/retry_after.*conflict|conflict.*Retry-After/i,
        'redirect rejects conflicting semantic and raw Retry-After values');
};

done_testing;
