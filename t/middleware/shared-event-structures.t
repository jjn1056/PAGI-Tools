use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use lib 'lib';
use PAGI::Middleware::Runtime;
use PAGI::Middleware::Debug;
use PAGI::Middleware::SecurityHeaders;
use PAGI::Middleware::CORS;
use PAGI::Middleware::RequestId;
use PAGI::Middleware::CSRF;
use PAGI::Middleware::Session;
use PAGI::Middleware::Cookie;
use PAGI::Utils::Middleware qw(wrap_response_headers);
use Storable qw(dclone);
use PAGI::Middleware::BufferedResponse qw(buffer_whole_response stream_transform_response);

my @shared;
sub shared_app { my ($body, $type) = @_; $body //= 'ok'; $type //= 'text/plain';
    @shared = (['content-type', $type], ['content-length', length $body]);
    return async sub { my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => \@shared });
        await $send->({ type => 'http.response.body', body => $body, more => 0 });
    };
}
sub request { my ($app, %scope) = @_;
    my @events;
    $app->({ type => 'http', method => 'GET', path => '/', headers => [], %scope },
        sub { Future->done({ type => 'http.disconnect' }) },
        sub { my ($e) = @_; push @events, $e; Future->done })->get;
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
    my $app = PAGI::Middleware::Runtime->new->wrap(async sub { my ($scope, $receive, $send) = @_;
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

sub app_sending { my (@start) = @_;
    return async sub { my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, @start });
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
    };
}
sub values_of { my ($events, $name) = @_;
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
    my $from = sub { my ($origin) = @_;
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

subtest 'two requests in flight, a layer suspended between edit and send' => sub {
    my @mine = (['content-type', 'text/plain']);
    my $snapshot = dclone(\@mine);
    my %gate;
    my $suspending = sub {
        my ($inner) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            my $id = $scope->{'test.id'};
            my $wrapped = wrap_response_headers($send, async sub {
                my ($headers) = @_;
                $headers->set('X-Probe', $id);
                await($gate{$id} = Future->new);
            });
            await $inner->($scope, $receive, $wrapped);
        };
    };
    my $stack = PAGI::Middleware::Runtime->new->wrap(
        PAGI::Middleware::CORS->new(origins => ['https://a.example', 'https://b.example'])->wrap(
            $suspending->(
                PAGI::Middleware::SecurityHeaders->new->wrap(
                    PAGI::Middleware::RequestId->new->wrap(app_sending(headers => \@mine))))));
    my (%events, @requests);
    for my $id (qw(A B)) {
        push @requests, $stack->(
            { type => 'http', method => 'GET', path => '/', 'test.id' => $id,
              headers => [['origin', $id eq 'A' ? 'https://a.example' : 'https://b.example']] },
            sub { Future->done({ type => 'http.disconnect' }) },
            sub { push @{ $events{$id} }, $_[0]; Future->done });
    }
    ok $gate{A} && $gate{B}, 'both requests are suspended between edit and send';
    $gate{B}->done;
    $gate{A}->done;
    $_->get for @requests;
    is values_of($events{A}, 'X-Probe'), ['A'], 'A carries only its own value';
    is values_of($events{B}, 'X-Probe'), ['B'], 'B carries only its own value';
    is values_of($events{A}, 'Access-Control-Allow-Origin'), ['https://a.example'], "A: its own origin";
    is values_of($events{B}, 'Access-Control-Allow-Origin'), ['https://b.example'], "B: its own origin";
    for my $id (qw(A B)) {
        is scalar @{ values_of($events{$id}, $_) }, 1, "$id: one $_"
            for 'X-Request-ID', 'X-Runtime', 'X-Frame-Options';
    }
    isnt values_of($events{A}, 'X-Request-ID'), values_of($events{B}, 'X-Request-ID'),
        'each its own request ID';
    is \@mine, $snapshot, "the app's array and pairs are untouched";
};

subtest 'RequestId, CSRF, Session and Cookie leave a shared array alone' => sub {
    for my $case (
        [RequestId => PAGI::Middleware::RequestId->new],
        [CSRF      => PAGI::Middleware::CSRF->new(secret => 's')],
        [Session   => PAGI::Middleware::Session->new],
        [Cookie    => PAGI::Middleware::Cookie->new],
    ) {
        my ($name, $mw) = @$case;
        my @mine = (['content-type', 'text/plain']);
        my $snapshot = dclone(\@mine);
        my $app = $mw->wrap(app_sending(headers => \@mine));
        request($app) for 1 .. 5;
        is \@mine, $snapshot, "$name: the app's array and pairs are untouched";
    }
};

subtest "BufferedResponse callbacks edit their own pairs, not the app's" => sub {
    # The app's page headers, built once; guests' pages are made cacheable by
    # editing the Cache-Control pair in the helper's copy.
    my @page = (['Content-Type', 'text/html'], ['Cache-Control', 'no-cache']);
    my $app = app_sending(headers => \@page);
    my $guest_cacheable = sub {
        my ($helper) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            my $guest = !grep { $_->[0] eq 'cookie' } @{ $scope->{headers} };
            my $edit = sub {
                my ($headers) = @_;
                return unless $guest;
                $_->[1] = 'public, max-age=300' for grep { lc $_->[0] eq 'cache-control' } @$headers;
            };
            await $helper->($edit)->($scope, $receive, $send);
        };
    };
    my %helpers = (
        buffer_whole_response => sub {
            my ($edit) = @_;
            buffer_whole_response($app, transform => sub { $edit->($_[1]); return @_ });
        },
        stream_transform_response => sub {
            my ($edit) = @_;
            stream_transform_response($app, begin => sub {
                $edit->($_[1]);
                return { chunk => sub { $_[0] }, finish => sub { '' } };
            });
        },
    );
    for my $name (sort keys %helpers) {
        @page = (['Content-Type', 'text/html'], ['Cache-Control', 'no-cache']);
        my $site = $guest_cacheable->($helpers{$name});
        my $alice = [['cookie', 'session=alice']];
        my (undef, $first)  = request($site, headers => $alice);
        my (undef, $guest)  = request($site);
        my (undef, $second) = request($site, headers => $alice);
        is values_of($first,  'Cache-Control'), ['no-cache'], "$name: alice first";
        is values_of($guest,  'Cache-Control'), ['public, max-age=300'], "$name: the guest";
        is values_of($second, 'Cache-Control'), ['no-cache'], "$name: alice after a guest";
        is $page[1][1], 'no-cache', "$name: the app's own pair is unchanged";
    }
};

subtest 'nothing in lib or examples teaches writing into a received header list' => sub {
    require File::Find;
    my @hits;
    File::Find::find(sub {
        return unless -f && /\.(?:pm|pl|pod|t)\z/;
        open my $fh, '<', $_ or die "$File::Find::name: $!";
        while (my $line = <$fh>) {
            push @hits, "$File::Find::name:$." if $line =~ /push\s*\@\{\s*\$\w+->\{headers\}\s*\}/;
        }
    }, 'lib', 'examples');
    is \@hits, [], 'no push into $event->{headers}';
};

done_testing;
