use v5.40;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use lib 'lib';
use PAGI::Middleware::Runtime;
use PAGI::Middleware::Debug;
use PAGI::Middleware::SecurityHeaders;
use PAGI::Middleware::CORS;

my @shared;
sub shared_app ($body = 'ok', $type = 'text/plain') {
    @shared = (['content-type', $type], ['content-length', length $body]);
    return async sub ($scope, $receive, $send) {
        await $send->({ type => 'http.response.start', status => 200, headers => \@shared });
        await $send->({ type => 'http.response.body', body => $body, more => 0 });
    };
}
sub request ($app, %scope) {
    my @events;
    $app->({ type => 'http', method => 'GET', path => '/', headers => [], %scope },
        sub { Future->done({ type => 'http.disconnect' }) },
        sub ($e) { push @events, $e; Future->done })->get;
    return [ map { lc $_->[0] } @{ $events[0]{headers} } ], \@events;
}

subtest 'Runtime' => sub {
    my $app = PAGI::Middleware::Runtime->new->wrap(shared_app());
    request($app) for 1 .. 4;
    my ($names) = request($app);
    is scalar(grep { $_ eq 'x-runtime' } @$names), 1, 'one X-Runtime on the fifth request';
    is scalar(@shared), 2, "the app's array is untouched";
};

subtest "Runtime leaves an app's own X-Runtime and warns" => sub {
    my $app = PAGI::Middleware::Runtime->new->wrap(async sub ($scope, $receive, $send) {
        await $send->({ type => 'http.response.start', status => 200,
            headers => [['content-type', 'text/plain'], ['X-Runtime', 'app-set']] });
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
    });
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my (undef, $events) = request($app);
    is [ map { $_->[1] } grep { lc($_->[0]) eq 'x-runtime' } @{ $events->[0]{headers} } ],
        ['app-set'], "the app's value is the only one";
    is scalar(@warnings), 1, 'one warning';
    like $warnings[0], qr/already has an X-Runtime header/, 'saying so';
};

subtest 'Debug rewrites Content-Length on its own pairs' => sub {
    my $html = '<html><body>hi</body></html>';
    my $app = PAGI::Middleware::Debug->new(enabled => 1)->wrap(shared_app($html, 'text/html'));
    request($app);
    is $shared[1][1], length($html), "the app's Content-Length pair is unchanged";
};

sub app_sending (@start) {
    return async sub ($scope, $receive, $send) {
        await $send->({ type => 'http.response.start', status => 200, @start });
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
    };
}
sub values_of ($events, $name) {
    return [ map { $_->[1] } grep { lc($_->[0]) eq lc $name } @{ $events->[0]{headers} } ];
}

subtest 'SecurityHeaders' => sub {
    my @mine = (['content-type', 'text/plain']);
    my $mw = PAGI::Middleware::SecurityHeaders->new;
    my $shared = $mw->wrap(app_sending(headers => \@mine));
    my $events;
    (undef, $events) = request($shared) for 1 .. 5;
    is scalar(@mine), 1, "the app's array is untouched";
    is values_of($events, 'X-Frame-Options'), ['SAMEORIGIN'], 'one X-Frame-Options';

    (undef, $events) = request($mw->wrap(app_sending()));
    is values_of($events, 'X-Frame-Options'), ['SAMEORIGIN'], 'added when the app omits headers';

    my $route = PAGI::Middleware::SecurityHeaders->new(content_security_policy => "default-src 'self'")
        ->wrap(app_sending(headers => [['Content-Security-Policy', "default-src 'none'"]]));
    (undef, $events) = request($route);
    is values_of($events, 'Content-Security-Policy'), ["default-src 'none'"], "a route's own CSP wins";
};

subtest 'CORS' => sub {
    my @mine = (['content-type', 'text/plain']);
    my $mw = PAGI::Middleware::CORS->new(origins => ['https://a.example', 'https://b.example']);
    my $shared = $mw->wrap(app_sending(headers => \@mine));
    my $from = sub ($origin) {
        my (undef, $events) = request($shared, headers => $origin ? [['origin', $origin]] : []);
        return values_of($events, 'Access-Control-Allow-Origin');
    };
    is $from->('https://a.example'), ['https://a.example'], 'allowed a: its own origin';
    is $from->('https://b.example'), ['https://b.example'], 'allowed b: only its own origin';
    is $from->('https://evil.example'), [], 'a disallowed origin: none';
    is $from->(undef), [], 'no origin: none';
    is scalar(@mine), 1, "the app's array is untouched";

    my (undef, $events) = request($mw->wrap(app_sending()), headers => [['origin', 'https://a.example']]);
    is values_of($events, 'Access-Control-Allow-Origin'), ['https://a.example'],
        'added when the app omits headers';

    (undef, $events) = request($mw->wrap(app_sending(headers => [['Access-Control-Allow-Origin', '*']])),
        headers => [['origin', 'https://a.example']]);
    is values_of($events, 'Access-Control-Allow-Origin'), ['https://a.example'], "one value: CORS's";
};

done_testing;
