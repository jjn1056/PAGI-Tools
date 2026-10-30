use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use File::Temp qw(tempdir);

use lib 'lib';
use PAGI::App::Directory;
use PAGI::Middleware::AccessLog;
use PAGI::Middleware::ContentNegotiation;
use PAGI::Middleware::Cookie;
use PAGI::Middleware::CORS;
use PAGI::Middleware::CSRF;
use PAGI::Middleware::GZip;
use PAGI::Middleware::MethodOverride;
use PAGI::Middleware::RequestId;
use PAGI::Middleware::ReverseProxy;
use PAGI::Middleware::Session::State::Cookie;
use PAGI::Middleware::Session::State::Header;

# The library reads a request through PAGI::HTTPConnection, each caller
# keeping its own semantics (spec 2026-10-30, phase 1 section 5). A value
# checked against something reads every field joined ", " (D1), so a repeated
# field fails the check; a value used as a value (an address, a scheme, a
# port, a session id, a method, a request id) reads get_single, so a repeated
# field counts as absent; cookies come from every Cookie field, the last of a
# name winning, never percent-decoded (D5).

sub http_scope {
    my (%opts) = @_;
    return {
        type         => 'http',
        method       => $opts{method} // 'GET',
        path         => '/',
        raw_path     => '/',
        query_string => $opts{query_string} // '',
        scheme       => 'http',
        headers      => $opts{headers} // [],
        client       => ['10.0.0.1', 4000],
        server       => ['127.0.0.1', 80],
    };
}

# Runs $middleware over $scope; returns the scope the application saw (undef
# when it did not run) and the events sent.
sub run_middleware {
    my ($middleware, $scope, %opts) = @_;
    my ($seen, @events);
    my $body = $opts{body} // 'ok';
    my $app = async sub {
        my ($inner, $receive, $send) = @_;
        $seen = $inner;
        await $send->({ type => 'http.response.start', status => 200,
            headers => [['content-type', $opts{content_type} // 'text/plain']] });
        await $send->({ type => 'http.response.body', body => $body, more => 0 });
    };
    my @request = @{ $opts{request} // [{ type => 'http.request', body => '', more => 0 }] };
    my $receive = async sub { @request ? shift @request : { type => 'http.disconnect' } };
    $middleware->wrap($app)->($scope, $receive, async sub { push @events, $_[0] })->get;
    return ($seen, \@events);
}

sub header_of {
    my ($event, $name) = @_;
    my @values = map { $_->[1] } grep { lc($_->[0]) eq lc($name) } @{ $event->{headers} // [] };
    return @values ? $values[0] : undef;
}

subtest 'ContentNegotiation reads every Accept field, as before' => sub {
    my $negotiation = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['text/html', 'application/json']);
    my ($seen) = run_middleware($negotiation, http_scope(
        headers => [['Accept', 'image/png'], ['Accept', 'application/json']]));
    is $seen->{'pagi.content_negotiation'}{type}, 'application/json',
        'the second Accept field still counts';
};

subtest 'GZip counts a repeated Accept-Encoding field' => sub {
    my $gzip = PAGI::Middleware::GZip->new(min_size => 10);
    my (undef, $events) = run_middleware($gzip, http_scope(
            headers => [['Accept-Encoding', 'identity'], ['Accept-Encoding', 'gzip']]),
        content_type => 'text/html', body => 'Hello World! This is a longer response body.');
    is header_of($events->[0], 'content-encoding'), 'gzip',
        'gzip in the second field compresses (the first field alone did not)';
};

subtest 'ReverseProxy: a repeated used value is absent' => sub {
    my $proxy = PAGI::Middleware::ReverseProxy->new(trust_all => 1);

    my ($seen) = run_middleware($proxy, http_scope(
        headers => [['X-Real-IP', '1.1.1.1'], ['X-Real-IP', '2.2.2.2']]));
    is $seen->{client}, ['10.0.0.1', 4000], 'two X-Real-IP fields leave the socket\'s client';
    ok !exists $seen->{'pagi.original_client'}, 'and record no original client';

    ($seen) = run_middleware($proxy, http_scope(
        headers => [['X-Real-IP', '1.1.1.1']]));
    is $seen->{client}, ['1.1.1.1', 4000], 'one X-Real-IP field is the client';

    ($seen) = run_middleware($proxy, http_scope(
        headers => [['X-Forwarded-Proto', 'https'], ['X-Forwarded-Proto', 'http']]));
    is $seen->{scheme}, 'http', 'two X-Forwarded-Proto fields leave the socket\'s scheme';

    ($seen) = run_middleware($proxy, http_scope(
        headers => [['X-Forwarded-Port', '8443'], ['X-Forwarded-Port', '9443']]));
    is $seen->{server}, ['127.0.0.1', 80], 'two X-Forwarded-Port fields leave the socket\'s port';

    ($seen) = run_middleware($proxy, http_scope(
        headers => [['X-Forwarded-Proto', 'https'], ['X-Forwarded-Port', '8443']]));
    is [$seen->{scheme}, $seen->{server}], ['https', ['127.0.0.1', 8443]],
        'one of each is used';
};

subtest 'ReverseProxy: X-Forwarded-For is read joined; X-Forwarded-Host still refused twice' => sub {
    my $proxy = PAGI::Middleware::ReverseProxy->new(trust_all => 1);
    for my $case (
        ['one field', [['X-Forwarded-For', '1.1.1.1, 2.2.2.2']]],
        ['two fields', [['X-Forwarded-For', '1.1.1.1'], ['X-Forwarded-For', '2.2.2.2']]],
    ) {
        my ($label, $headers) = @$case;
        my ($seen) = run_middleware($proxy, http_scope(headers => $headers));
        is $seen->{client}, ['1.1.1.1', 4000], "$label: the leftmost address";
    }

    my ($seen, $events) = run_middleware($proxy, http_scope(
        headers => [['X-Forwarded-Host', 'a.example'], ['X-Forwarded-Host', 'b.example']]));
    is [$seen, $events->[0]{status}], [undef, 400], 'two X-Forwarded-Host fields are refused';
};

subtest 'CORS checks a repeated Origin joined, so it does not match' => sub {
    my $cors = PAGI::Middleware::CORS->new(origins => ['https://a.example']);
    my (undef, $events) = run_middleware($cors, http_scope(
        headers => [['Origin', 'https://a.example'], ['Origin', 'https://evil.example']]));
    is header_of($events->[0], 'access-control-allow-origin'), undef,
        'no Access-Control-Allow-Origin for two Origin fields';

    (undef, $events) = run_middleware($cors, http_scope(
        headers => [['Origin', 'https://a.example']]));
    is header_of($events->[0], 'access-control-allow-origin'), 'https://a.example',
        'one allowed Origin is answered';
};

subtest 'CSRF reads through the connection' => sub {
    my $csrf = PAGI::Middleware::CSRF->new(refuse => 0, form_field => 'csrf_token',
        trusted_origins => ['https://a.example']);
    my $failure = sub {
        my (%opts) = @_;
        my ($seen) = run_middleware($csrf, http_scope(method => 'POST', headers => $opts{headers}),
            request => $opts{request});
        return $seen->{'pagi.csrf_failure'} // 'none';
    };

    is $failure->(headers => [['Cookie', 'a=1; csrf_token=x; csrf_token=y'], ['X-CSRF-Token', 'y']]),
        'none', 'the last of a repeated cookie name is the stored token';
    is $failure->(headers => [['Cookie', 'a=1'], ['Cookie', 'csrf_token=y'], ['X-CSRF-Token', 'y']]),
        'none', 'a token in the second Cookie field is read';
    is $failure->(headers => [['Cookie', 'csrf_token=y'], ['X-CSRF-Token', 'y'], ['X-CSRF-Token', 'y']]),
        'mismatch', 'a repeated token header reads joined and does not match';
    is $failure->(headers => [['Cookie', 'csrf_token=y'], ['X-CSRF-Token', 'y'],
            ['Origin', 'https://a.example'], ['Origin', 'https://evil.example']]),
        'cross_origin', 'a repeated Origin reads joined: not trusted, not the Host';

    my $form = [{ type => 'http.request', body => 'csrf_token=y', more => 0 }];
    is $failure->(headers => [['Cookie', 'csrf_token=y'],
            ['Content-Type', 'Application/X-WWW-Form-Urlencoded; charset=UTF-8']], request => $form),
        'none', 'a form Content-Type in any case, with parameters, takes the form-token branch';
    is $failure->(headers => [['Cookie', 'csrf_token=y'],
            ['Content-Type', 'application/x-www-form-urlencoded'],
            ['Content-Type', 'application/x-www-form-urlencoded']], request => $form),
        'missing_token', 'a duplicate Content-Type does not';

    my ($seen, $events) = run_middleware($csrf, http_scope(headers => [['Cookie', 'csrf_token=']]));
    my $minted = header_of($events->[0], 'set-cookie');
    like $minted, qr/\Acsrf_token=[0-9a-f]{64}; /, 'an empty token cookie is no token: one is minted';
    is length($seen->{'pagi.csrf_token'}), 64, 'and published';
};

subtest 'Session::State::Cookie reads every Cookie field (D5)' => sub {
    my $state = PAGI::Middleware::Session::State::Cookie->new;
    my $extract = sub { $state->extract(http_scope(headers => [map { ['Cookie', $_] } @_])) };
    is $extract->('a=1', 'pagi_session=s1'), 's1', 'the session cookie in a second Cookie field';
    is $extract->('pagi_session=first; pagi_session=last'), 'last', 'the last duplicate wins';
    is $extract->('pagi_session=x%2Fy'), 'x%2Fy', 'percent-encoding kept';
    is $extract->('pagi_session="quoted"'), 'quoted', 'a quoted value is unquoted';
};

subtest 'the Cookie middleware reads every Cookie field (D5)' => sub {
    my $cookie = PAGI::Middleware::Cookie->new;
    my ($seen) = run_middleware($cookie, http_scope(headers => [
        ['Cookie', 'a=1; b=x%2Fy'], ['Cookie', 'a=2; c="q"']]));
    is $seen->{'pagi.cookies'}, { a => '2', b => 'x%2Fy', c => 'q' },
        'two fields read, the last duplicate wins, %2F kept, quotes removed';
};

subtest 'Session::State::Header: a repeated session header is absent' => sub {
    my $state = PAGI::Middleware::Session::State::Header->new(header_name => 'X-Session-ID');
    is $state->extract(http_scope(headers => [['X-Session-ID', 'a'], ['X-Session-ID', 'b']])),
        undef, 'two fields: no session id';
    is $state->extract(http_scope(headers => [['X-Session-ID', 'a']])), 'a', 'one field: its value';
};

subtest 'AccessLog logs repeated Referer and User-Agent joined' => sub {
    my @lines;
    my $log = PAGI::Middleware::AccessLog->new(logger => sub { push @lines, @_ });
    run_middleware($log, http_scope(headers => [
        ['User-Agent', 'one'], ['User-Agent', 'two'],
        ['Referer', 'https://r1.example/'], ['Referer', 'https://r2.example/']]));
    like $lines[0], qr/"https:\/\/r1\.example\/, https:\/\/r2\.example\/" "one, two" /,
        'both fields of each, in order';
};

subtest 'MethodOverride' => sub {
    my $override = PAGI::Middleware::MethodOverride->new;
    my $method = sub {
        my ($seen) = run_middleware($override, http_scope(method => 'POST', @_));
        return $seen->{method};
    };
    is $method->(headers => [['X-HTTP-Method-Override', 'PUT'], ['X-HTTP-Method-Override', 'DELETE']]),
        'POST', 'a repeated override header is absent';
    is $method->(headers => [['X-HTTP-Method-Override', 'PUT'], ['X-HTTP-Method-Override', 'DELETE']],
            query_string => '_method=PATCH'),
        'PATCH', 'and the query parameter then applies';
    is $method->(headers => [['X-HTTP-Method-Override', 'DELETE']], query_string => '_method=PATCH'),
        'DELETE', 'one override header comes first';
    is $method->(query_string => '_method=PUT'), 'PUT', '_method=PUT';
    is $method->(query_string => '_method=P%55T'), 'PUT', '_method=P%55T is decoded';
    is $method->(query_string => '_method=PUT&_method=DELETE'), 'DELETE',
        'a repeated _method: the last wins';
    is $method->(query_string => 'x=1;_method=PUT'), 'PUT', "';' separates parameters";
};

subtest 'RequestId: a repeated incoming id is absent, so a new one is made' => sub {
    my $request_id = PAGI::Middleware::RequestId->new(
        trust_incoming => 1, generator => sub { 'generated' });
    my ($seen) = run_middleware($request_id, http_scope(
        headers => [['X-Request-ID', 'a'], ['X-Request-ID', 'b']]));
    is $seen->{'pagi.request_id'}, 'generated', 'two fields: a generated id';
    ($seen) = run_middleware($request_id, http_scope(headers => [['X-Request-ID', 'a']]));
    is $seen->{'pagi.request_id'}, 'a', 'one field: trusted';
};

subtest 'App::Directory checks every Accept field for JSON (D1)' => sub {
    my $root = tempdir(CLEANUP => 1);
    open my $fh, '>', "$root/a.txt" or die "a.txt: $!";
    print {$fh} 'a';
    close $fh or die "a.txt: $!";
    my $app = PAGI::App::Directory->new(root => $root)->to_app;
    my $type_for = sub {
        my @events;
        $app->(http_scope(headers => [map { ['Accept', $_] } @_]),
            async sub { { type => 'http.disconnect' } }, async sub { push @events, $_[0] })->get;
        return header_of($events[0], 'content-type');
    };
    like $type_for->('text/html', 'application/json'), qr{\Aapplication/json},
        'application/json in a second Accept field gets the JSON listing';
    like $type_for->('text/html'), qr{\Atext/html}, 'text/html alone gets HTML';
};

done_testing;
