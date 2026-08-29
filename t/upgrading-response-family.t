#!/usr/bin/env perl

use strict;
use warnings;

use Encode qw(encode);
use Future;
use JSON::MaybeXS qw(decode_json);
use Test2::V0;

use lib 'lib';

use PAGI::App::File;
use PAGI::Middleware::CORS;
use PAGI::Pages qw(not_found_page);
use PAGI::Request;
use PAGI::Response qw(:all);
use PAGI::Routing qw(request_app route);
use PAGI::SSE;
use PAGI::Utils qw(app_path);
use PAGI::WebSocket;

sub http_scope {
    my (%changes) = @_;
    my $path = $changes{path} // '/';
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

sub receive_http {
    return Future->done({
        type => 'http.request', body => '', more => 0,
    });
}

sub run_http {
    my ($app, $scope) = @_;
    my @events;
    $app->(
        $scope // http_scope(),
        \&receive_http,
        sub { push @events, $_[0]; Future->done },
    )->get;
    return \@events;
}

sub body_from {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

subtest 'Response factories replace the mutable builder and Request bridge' => sub {
    my $request = PAGI::Request->new(http_scope(), \&receive_http);
    ok(!$request->can('response'), 'Request no longer manufactures a Response');

    my @removed = qw(
        text html json send send_raw redirect empty send_file stream
        scope is_sent has_body_source cors writer
    );
    for my $method (@removed) {
        ok(!PAGI::Response->can($method), "removed Response method $method has no alias");
    }

    my @matrix = (
        [response('bytes'),                  'PAGI::Response'],
        [text_response('text'),              'PAGI::Response::Text'],
        [html_response('<b>html</b>'),       'PAGI::Response::HTML'],
        [json_response({ ok => \1 }),         'PAGI::Response::JSON'],
        [problem_response({ status => 409 }), 'PAGI::Response::Problem'],
        [redirect_response('/next'),         'PAGI::Response::Redirect'],
        [empty_response(),                   'PAGI::Response::Empty'],
        [file_response(__FILE__),            'PAGI::Response::File'],
        [stream_response(sub { }),           'PAGI::Response::Stream'],
    );
    isa_ok($_->[0], $_->[1]) for @matrix;
};

subtest 'explicit bytes replace the custom-charset finisher' => sub {
    my $response = response(
        encode('ISO-8859-1', "caf\x{e9}"),
        content_type => 'text/plain; charset=iso-8859-1',
    );
    is($response->body, "caf\xe9", 'caller-owned encoding supplies exact bytes');
    is($response->content_type, 'text/plain; charset=iso-8859-1',
        'caller supplies the matching media-type parameter');
};

subtest 'scope state and CORS belong to request and middleware owners' => sub {
    my $scope = http_scope(headers => [['Origin' => 'https://example.test']]);
    my $request = PAGI::Request->new($scope, \&receive_http);
    is($request->raw, $scope, 'Request remains the HTTP scope source');

    my $app = PAGI::Middleware::CORS->new(
        origins => ['https://example.test'],
    )->wrap(text_response('ok')->to_app);
    my $events = run_http($app, $scope);
    my ($start) = grep { $_->{type} eq 'http.response.start' } @$events;
    ok(grep({ lc($_->[0]) eq 'access-control-allow-origin'
            && $_->[1] eq 'https://example.test' } @{$start->{headers}}),
        'CORS middleware applies request-origin policy');

    my $literal = text_response('ok')->header(
        'Access-Control-Expose-Headers' => 'X-Request-ID',
    );
    is($literal->header('access-control-expose-headers'), 'X-Request-ID',
        'ordinary header remains available for one literal field');
};

subtest 'Stream owns Writer creation and each write is awaited' => sub {
    my @seen;
    my $stream = stream_response(sub {
        my ($writer) = @_;
        push @seen, ref($writer);
        return $writer->write('chunk');
    });
    my $events = run_http($stream->to_app);
    is(\@seen, ['PAGI::Response::Writer'], 'producer receives the invocation Writer');
    is(body_from($events), 'chunk', 'awaited Writer output reaches the wire');
};

subtest 'respond requires the complete native triplet' => sub {
    my $response = text_response('created', status => 201);
    like(dies { $response->respond(sub { Future->done })->get },
        qr/(?:HTTP scope|scope hashref)/i,
        'removed one-argument respond fails with the HTTP-scope diagnostic');

    my @events;
    $response->respond(
        http_scope(),
        \&receive_http,
        sub { push @events, $_[0]; Future->done },
    )->get;
    is([$events[0]{status}, body_from(\@events)], [201, 'created'],
        'full-triplet respond emits the complete response');
};

subtest 'File application construction has one unambiguous spelling' => sub {
    ok(!PAGI::App::File->can('app_path'),
        'removed class app_path constructor has no alias');
    local $ENV{PAGI_HOME} = '/tmp/pagi-tools-upgrading';
    isa_ok(PAGI::App::File->from_app_path('static'), 'PAGI::App::File');
    like(app_path('static'), qr{pagi-tools-upgrading/static\z},
        'utility app_path still returns a path string');
};

subtest 'Pages functions are Request handlers and request_app is explicit' => sub {
    like(dies { PAGI::Pages->not_found }, qr/metadata source/i,
        'removed no-source endpoint factory fails directly');

    my $route_app = route('/missing' => \&not_found_page)->to_app;
    my $route_events = run_http($route_app, http_scope(path => '/missing'));
    is($route_events->[0]{status}, 404,
        'ordinary Pages function executes as a Route handler');

    my $native = request_app(\&not_found_page);
    my $native_events = run_http($native);
    is($native_events->[0]{status}, 404,
        'request_app explicitly converts a Request handler for native placement');
};

subtest 'WebSocket denial and SSE decline take concrete Responses' => sub {
    my @ws_events;
    my $ws = PAGI::WebSocket->new(
        {
            type => 'websocket', method => 'GET', path => '/socket', headers => [],
            extensions => { 'websocket.http.response' => {} },
        },
        sub { Future->done({ type => 'websocket.connect' }) },
        sub { push @ws_events, $_[0]; Future->done },
    );
    like(dies { $ws->deny(status => 401, body => 'no')->get },
        qr/exactly one concrete PAGI::Response/i,
        'removed WebSocket denial option list fails directly');
    $ws->deny(text_response('no', status => 401))->get;
    is([map { $_->{type} } @ws_events], [
        'websocket.http.response.start', 'websocket.http.response.body',
    ], 'Response-valued WebSocket denial executes');

    my @sse_events;
    my $sse = PAGI::SSE->new(
        { type => 'sse', method => 'GET', path => '/events', headers => [] },
        sub { Future->new },
        sub { push @sse_events, $_[0]; Future->done },
    );
    like(dies { $sse->decline(status => 404, body => 'missing')->get },
        qr/exactly one concrete PAGI::Response/i,
        'removed SSE decline option list fails directly');
    $sse->decline(text_response('missing', status => 404))->get;
    is([map { $_->{type} } @sse_events], [
        'sse.http.response.start', 'sse.http.response.body',
    ], 'Response-valued SSE decline executes');
};

subtest 'JSON migration asserts values, never object member order' => sub {
    my $response = json_response({ beta => 2, alpha => 1 });
    is(decode_json($response->body), { alpha => 1, beta => 2 },
        'JSON response contract is semantic, independent of serialized key order');
};

done_testing;
