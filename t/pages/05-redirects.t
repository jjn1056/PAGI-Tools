use strict;
use warnings;

use Test2::V0;
use Encode qw(decode FB_CROAK);
use Future;
use JSON::MaybeXS qw(decode_json);

use PAGI::Context;
use PAGI::Pages;

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
    my ($response) = @_;
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    Future->wrap($response->respond($send))->get;
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
    my ($response) = @_;
    return decode('UTF-8', body(send_response($response)), FB_CROAK);
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
        my $response = PAGI::Pages->$method(http_scope(), @args, as => 'text');
        is($response->status, $status, "$method has status $status");
        like(decoded_body($response), qr/\Q$status $title\E/,
            "$method renders its registered title");
    }

    for my $status (300, 304, 305, 306, 309, 399, '302.0', 'x') {
        like(dies { PAGI::Pages->redirect('/next', status => $status) },
            qr/status.*301.*302.*303.*307.*308/i,
            "generic redirect rejects unsupported status $status");
    }
    like(dies { PAGI::Pages->found('/next', status => 302) }, qr/status/i,
        'named redirect rejects a supplied status option even when it matches');
};

subtest 'redirect supports immediate and deferred Pages invocation forms' => sub {
    my $scope = http_scope();
    my @events;
    my $send = sub { push @events, $_[0]; return Future->done };
    my $context = PAGI::Context->new($scope, sub { Future->done }, $send);

    my $class = PAGI::Pages->redirect($context, '/class', as => 'text');
    is($class->header('Location'), '/class', 'class immediate Context call returns redirect');

    my $pages = PAGI::Pages->new(as => 'text');
    my $instance = $pages->found($scope, '/instance');
    is($instance->header('Location'), '/instance', 'instance immediate scope call returns redirect');

    my $endpoint = PAGI::Pages->see_other('/endpoint', as => 'text');
    is(ref($endpoint), 'CODE', 'deferred redirect is a plain coderef');
    is($endpoint->($context)->header('Location'), '/endpoint',
        'deferred Context call returns an unsent redirect');
    is($endpoint->($scope)->header('Location'), '/endpoint',
        'deferred scope-only call returns an unsent redirect');

    Future->wrap($endpoint->($scope, sub { Future->done }, $send))->get;
    is($events[0]{status}, 303, 'deferred native triplet sends the redirect');
};

subtest 'redirect validates its target and options before construction' => sub {
    for my $target ("/bad\nnext", "/wide\x{263a}", {}, []) {
        like(dies { PAGI::Pages->redirect(http_scope(), $target) },
            qr/target.*URI-reference/i,
            'redirect rejects control, wide, and reference targets');
    }
    is(PAGI::Pages->redirect('https://example.test/path')->(http_scope())
        ->header('Location'), 'https://example.test/path',
        'absolute target is preserved');
    is(PAGI::Pages->redirect('../relative/path')->(http_scope())
        ->header('Location'), '../relative/path', 'relative target is preserved');

    like(dies { PAGI::Pages->redirect('/next', type => 'https://example.test') },
        qr/unknown PAGI::Pages redirect option/, 'problem options are not redirect options');
    like(dies { PAGI::Pages->redirect('/next', preserve_query => []) },
        qr/preserve_query.*Boolean/i, 'preserve_query requires a Boolean scalar');
};

subtest 'redirect bodies and Location share the one final target' => sub {
    my $target = q{/next?existing=1&x=<tag>#part};

    my $html = PAGI::Pages->redirect(http_scope(), $target, as => 'html');
    is($html->header('Location'), $target, 'HTML Location is the exact target');
    my $html_body = decoded_body($html);
    like($html_body, qr{href="/next\?existing=1&amp;x=&lt;tag&gt;#part"},
        'HTML escapes the target in the href');
    like($html_body, qr{>/next\?existing=1&amp;x=&lt;tag&gt;#part</a>},
        'HTML escapes the target as link text');

    my $text = PAGI::Pages->redirect(http_scope(), $target, as => 'text');
    is(decoded_body($text), "302 Found\n\nThe requested resource has moved.\n\nLocation:\n$target\n",
        'text includes the unchanged final target');

    my $json = PAGI::Pages->permanent_redirect(http_scope(), $target, as => 'json');
    my $json_events = send_response($json);
    is(header($json_events, 'Content-Type'), 'application/json',
        'redirect JSON is ordinary application/json');
    is(decode_json(body($json_events)), {
        status => 308, location => $target,
        detail => 'The requested resource has moved.',
    }, 'redirect JSON contains the same exact location, not a problem document');
};

subtest 'redirect query preservation keeps raw data before the first fragment' => sub {
    my @cases = (
        ['/search',                   'q=perl', '/search?q=perl'],
        ['/search?',                  'q=perl', '/search?q=perl'],
        ['/search?sort=date',         'q=perl', '/search?sort=date&q=perl'],
        ['/search#results',           'q=perl', '/search?q=perl#results'],
        ['/search?sort=date#results', 'q=perl', '/search?sort=date&q=perl#results'],
        ['/search#results',           '',       '/search#results'],
    );

    for my $case (@cases) {
        my ($target, $query, $want) = @$case;
        my $scope = http_scope(query_string => $query);
        my $html = PAGI::Pages->redirect(
            $scope, $target, preserve_query => 1, as => 'html',
        );
        is($html->header('Location'), $want, "Location preserves '$target' with '$query'");
        my $html_body = decoded_body($html);
        my $escaped = $want;
        $escaped =~ s/&/&amp;/g;
        $escaped =~ s/</&lt;/g;
        $escaped =~ s/>/&gt;/g;
        $escaped =~ s/"/&quot;/g;
        $escaped =~ s/'/&#39;/g;
        like($html_body, qr{href="\Q$escaped\E"}, 'HTML href describes final target');
        like($html_body, qr{>\Q$escaped\E</a>}, 'HTML text describes final target');

        my $text = PAGI::Pages->redirect($scope, $target, preserve_query => 1, as => 'text');
        like(decoded_body($text), qr/\Q$want\E/, 'text describes final target');

        my $json = PAGI::Pages->redirect($scope, $target, preserve_query => 1, as => 'json');
        my $json_data = decode_json(body(send_response($json)));
        is($json_data->{location}, $want, 'JSON describes final target');
    }

    my $default = PAGI::Pages->redirect(
        http_scope(query_string => 'q=perl'), '/search#results', as => 'text',
    );
    is($default->header('Location'), '/search#results',
        'preserve_query defaults to false');
};

subtest 'query preservation rejects unsafe raw query data before response construction' => sub {
    my $safe = PAGI::Pages->redirect(
        http_scope(query_string => 'q=a%2Bb&x=%26'), '/search#results',
        preserve_query => 1, as => 'text',
    );
    is($safe->header('Location'), '/search?q=a%2Bb&x=%26#results',
        'safe percent-encoded raw query bytes are unchanged');

    for my $query ("q=ok\r\nInjected: yes", "q=ok\x1f", "q=\x{263a}") {
        like(dies {
            PAGI::Pages->redirect(
                http_scope(query_string => $query), '/search',
                preserve_query => 1, as => 'text',
            );
        }, qr/query_string.*URI-reference/i,
            'unsafe preserved query is rejected before response construction');

        my @events;
        my $endpoint = PAGI::Pages->redirect('/search',
            preserve_query => 1, as => 'text');
        like(dies {
            $endpoint->(
                http_scope(query_string => $query),
                sub { Future->done },
                sub { push @events, $_[0]; return Future->done },
            );
        }, qr/query_string.*URI-reference/i,
            'unsafe preserved query rejects native invocation before response start');
        is(\@events, [], 'unsafe preserved query emits no response event');
    }
};

subtest 'redirect cache and retry fields follow redirect policy' => sub {
    my $default = PAGI::Pages->redirect(http_scope(), '/next', as => 'text');
    is($default->header('Cache-Control'), undef,
        'redirects do not add Cache-Control by default');

    my $explicit = PAGI::Pages->redirect(
        http_scope(), '/next', as => 'text', cache_control => 'public, max-age=60',
        retry_after => 30,
    );
    is($explicit->header('Cache-Control'), 'public, max-age=60',
        'redirect accepts explicit cache policy');
    is($explicit->header('Retry-After'), '30',
        'redirect accepts Retry-After delay seconds');

    like(dies { PAGI::Pages->redirect(
        '/next', retry_after => 30, headers => ['Retry-After' => '60'],
    ) }, qr/retry_after.*conflict|conflict.*Retry-After/i,
        'redirect rejects conflicting semantic and raw Retry-After values');
};

done_testing;
