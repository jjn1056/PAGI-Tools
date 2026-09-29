use strict;
use warnings;

use Test2::V0;
use Future;
use JSON::MaybeXS qw(decode_json);
use PAGI::Headers ();
use Scalar::Util qw(blessed refaddr);

use PAGI::Pages;
use PAGI::Pages::Application;
use PAGI::Request;
use PAGI::SSE;
use PAGI::WebSocket;
use PAGI::Test::ConnectionState;

sub scope {
    my ($type, %args) = @_;
    return {
        type         => $type,
        method       => exists($args{method}) ? $args{method} : 'GET',
        path         => exists($args{path}) ? $args{path} : '/',
        headers      => $args{headers} || [],
        query_string => '',
        http_version => '1.1',
        ($type eq 'websocket' || $type eq 'sse'
            ? ('pagi.connection' => PAGI::Test::ConnectionState->new(websocket => $type eq 'websocket'))
            : ()),
    };
}

sub callbacks {
    return (sub { Future->done }, sub { Future->done });
}

sub problem_descriptor {
    return {
        kind               => 'error',
        status             => 401,
        title              => 'Unauthorized',
        detail             => 'Authentication is required to access this resource.',
        type               => 'about:blank',
        instance           => undef,
        extensions         => {},
        as                 => undef,
        headers            => ['WWW-Authenticate' => 'Bearer realm="api"'],
        cache_control      => 'no-store',
        login_url          => undef,
        upgrade_connection => 0,
    };
}

sub invoke_application {
    my ($application, $scope) = @_;
    my @events;
    Future->wrap($application->to_app->(
        $scope,
        sub { Future->done },
        sub { push @events, $_[0]; Future->done },
    ))->get;
    return \@events;
}

{
    package Local::ScopeSource;
    sub new { return bless { scope => $_[1] }, $_[0] }
    sub scope { return $_[0]{scope} }
}

{
    package Local::ThrowingScopeSource;
    sub new { return bless {}, $_[0] }
    sub scope { die "scope lookup exploded\n" }
}

{
    package Local::BlessedScopeHash;
}

{
    package Local::CountingPages;
    our @ISA = ('PAGI::Pages');
    our $RESPONSE_COUNT = 0;
    our $NEGOTIATION_COUNT = 0;
    our @RESPONSE_SCOPES;
    our @NEGOTIATION_SCOPES;

    sub _response_for {
        my ($self, $scope, $descriptor) = @_;
        ++$RESPONSE_COUNT;
        push @RESPONSE_SCOPES, $scope;
        return $self->SUPER::_response_for($scope, $descriptor);
    }

    sub _select_representation {
        my ($self, $scope, $descriptor) = @_;
        ++$NEGOTIATION_COUNT;
        push @NEGOTIATION_SCOPES, $scope;
        return $self->SUPER::_select_representation($scope, $descriptor);
    }
}

{
    package Local::FutureRendererPages;
    our @ISA = ('PAGI::Pages');
    sub render_problem { return Future->done({ status => 401 }) }
}

{
    package Local::CountingApplication;
    our @ISA = ('PAGI::Pages::Application');
    our $MATERIALIZE_COUNT = 0;

    sub _materialize_scope {
        my $self = shift;
        ++$MATERIALIZE_COUNT;
        return $self->SUPER::_materialize_scope(@_);
    }
}

subtest 'response_for materializes fresh concrete problem responses for request-like scopes' => sub {
    my $application = PAGI::Pages->unauthorized(
        challenge => 'Bearer realm="api"',
        as        => 'json',
    );

    my @raw_scopes = (
        scope('http'),
        scope('websocket', path => '/chat'),
        scope('sse', path => '/events'),
    );

    for my $source (@raw_scopes) {
        my $response = $application->response_for($source);
        isa_ok($response, ['PAGI::Response::Problem'],
            "$source->{type} scope materializes a problem response");
        is($response->status, 401, "$source->{type} response retains status");
        is($response->content_type, 'application/problem+json',
            "$source->{type} response retains the selected representation");
        is($response->header_all('WWW-Authenticate'), ['Bearer realm="api"'],
            "$source->{type} response retains its challenge");
        is(decode_json($response->body), {
            type   => 'about:blank',
            title  => 'Unauthorized',
            status => 401,
            detail => 'Authentication is required to access this resource.',
        }, "$source->{type} response retains the complete problem body");
    }

    my ($receive, $send) = callbacks();
    my @objects = (
        PAGI::Request->new(scope('http'), $receive),
        PAGI::WebSocket->new(scope('websocket'), $receive, $send),
        PAGI::SSE->new(scope('sse'), $receive, $send),
    );
    for my $source (@objects) {
        isa_ok($application->response_for($source), ['PAGI::Response::Problem'],
            ref($source) . ' supplies request metadata through scope()');
    }

    my $one = $application->response_for(scope('websocket'));
    my $two = $application->response_for(scope('websocket'));
    isnt(refaddr($one), refaddr($two),
        'repeated materialization creates fresh concrete responses');
};

subtest 'negotiated HTTP materialization preserves source scopes and header caches' => sub {
    for my $kind (qw(raw request)) {
        for my $cached (0, 1) {
            local @Local::CountingPages::RESPONSE_SCOPES;
            local @Local::CountingPages::NEGOTIATION_SCOPES;
            my @descriptor_scopes;
            my $policy = Local::CountingPages->new(as => 'auto', default => 'text');
            my $application = PAGI::Pages::Application->new(
                policy => $policy,
                descriptor_factory => sub {
                    push @descriptor_scopes, $_[0];
                    return problem_descriptor();
                },
            );
            my $scope = scope('http', headers => [
                ['Accept' => 'text/html;q=0.1'],
                ['Accept' => 'application/problem+json;q=0.9'],
            ]);
            my $request = PAGI::Request->new($scope, sub {
                die 'materialization must not receive';
            });
            my $cache = $cached ? $request->headers : undef;
            my $source = $kind eq 'raw' ? $scope : $request;
            my @keys = sort keys %$scope;
            my $headers = $scope->{headers};
            my $label = "$kind cached=$cached";
            for my $call (1, 2) {
                my $response = $application->response_for($source);
                is($response->content_type, 'application/problem+json',
                    "$label call $call negotiates repeated Accept fields");
                is([sort keys %$scope], \@keys,
                    "$label call $call preserves source keys");
                is(refaddr($scope->{headers}), refaddr($headers),
                    "$label call $call preserves raw header identity");
                is($scope->{headers}, [
                    ['Accept' => 'text/html;q=0.1'],
                    ['Accept' => 'application/problem+json;q=0.9'],
                ], "$label call $call preserves raw header values");
                if ($cached) {
                    is(refaddr($scope->{'pagi.request.headers'}), refaddr($cache),
                        "$label call $call preserves cache identity");
                    is([$cache->get_all('accept')], [
                        'text/html;q=0.1', 'application/problem+json;q=0.9',
                    ], "$label call $call preserves cached header values");
                }
                else {
                    ok(!exists $scope->{'pagi.request.headers'},
                        "$label call $call leaves source uncached");
                }
                is(refaddr($descriptor_scopes[-1]), refaddr($scope),
                    "$label call $call descriptor retains original scope identity");
                my $metadata = $Local::CountingPages::RESPONSE_SCOPES[-1];
                isnt(refaddr($metadata), refaddr($scope),
                    "$label call $call policy receives an isolated metadata copy");
                is(refaddr($Local::CountingPages::NEGOTIATION_SCOPES[-1]),
                    refaddr($metadata),
                    "$label call $call negotiation shares the policy metadata copy");
                is($metadata->{type}, 'http',
                    "$label call $call metadata retains the real HTTP type");
                ok(!exists $metadata->{'pagi.request.headers'},
                    "$label call $call metadata does not inherit the source header cache");
            }
        }
    }
};

subtest 'response_for validates the exact source grammar and request type' => sub {
    my $application = PAGI::Pages->unauthorized(
        challenge => 'Bearer realm="api"', as => 'json',
    );

    like(dies { $application->response_for }, qr/exactly one.*scope/i,
        'a source is required');
    like(dies { $application->response_for(scope('http'), as => 'text') },
        qr/exactly one.*scope/i, 'materialization options are rejected');

    for my $bad_source (undef, [], 'http', bless({type => 'http'}, 'Local::BlessedScopeHash')) {
        like(dies { $application->response_for($bad_source) },
            qr/unblessed scope hashref.*scope\(\)/i,
            'an invalid source is rejected');
    }

    for my $bad_scope (
        {},
        {type => undef},
        {type => ''},
        {type => []},
    ) {
        like(dies { $application->response_for($bad_scope) },
            qr/response_for.*scope type is required/i,
            'a missing or invalid scalar type is rejected');
    }

    my $blessed_scope = bless({type => 'http'}, 'Local::BlessedScopeHash');
    like(dies {
        $application->response_for(Local::ScopeSource->new($blessed_scope));
    }, qr/unblessed scope hashref/i,
        'scope() must return an unblessed scope hashref');
    like(dies {
        $application->response_for(Local::ThrowingScopeSource->new);
    }, qr/scope lookup exploded/i, 'scope() exceptions propagate');
    like(dies { $application->response_for({type => 'lifespan'}) },
        qr/response_for.*lifespan/i, 'lifespan is not request metadata');
    like(dies { $application->response_for({type => 'example.custom'}) },
        qr/response_for.*HTTP, WebSocket, or SSE.*example\.custom/i,
        'custom scope types are not coerced into request metadata');

    local $Local::CountingPages::RESPONSE_COUNT = 0;
    my $descriptor_count = 0;
    my $guarded = PAGI::Pages::Application->new(
        policy             => Local::CountingPages->new(as => 'text'),
        descriptor_factory => sub {
            ++$descriptor_count;
            return problem_descriptor();
        },
    );
    for my $type (qw(lifespan example.custom)) {
        my $error = dies { $guarded->response_for({type => $type}) };
        ok($error, "$type response_for materialization is rejected");
    }
    is($descriptor_count, 0,
        'unsupported response_for scopes are rejected before descriptor creation');
    is($Local::CountingPages::RESPONSE_COUNT, 0,
        'unsupported response_for scopes are rejected before rendering');
};

subtest 'response_for rejects asynchronous descriptor and renderer results' => sub {
    my $future_descriptor = PAGI::Pages::Application->new(
        policy             => PAGI::Pages->new(as => 'json'),
        descriptor_factory => sub { Future->done(problem_descriptor()) },
    );
    like(dies { $future_descriptor->response_for(scope('http')) },
        qr/descriptor.*immediate|immediate.*descriptor/i,
        'a descriptor Future is rejected synchronously');

    my $future_renderer = Local::FutureRendererPages->unauthorized(
        challenge => 'Bearer realm="api"', as => 'json',
    );
    like(dies { $future_renderer->response_for(scope('http')) },
        qr/renderer.*immediate/i,
        'a renderer Future is rejected synchronously');
};

subtest 'materialization gives policy a shallow real-protocol metadata view without changing the source' => sub {
    local $Local::CountingPages::RESPONSE_COUNT = 0;
    local $Local::CountingPages::NEGOTIATION_COUNT = 0;
    local @Local::CountingPages::RESPONSE_SCOPES;
    local @Local::CountingPages::NEGOTIATION_SCOPES;

    my $descriptor_count = 0;
    my @descriptor_scopes;
    my $policy = Local::CountingPages->new(as => 'auto', default => 'text');
    my $application = PAGI::Pages::Application->new(
        policy             => $policy,
        descriptor_factory => sub {
            ++$descriptor_count;
            push @descriptor_scopes, $_[0];
            return problem_descriptor();
        },
    );

    my $nested = { request_id => 'nested-by-identity' };
    my $headers = [['Accept' => 'application/problem+json']];
    my $protocol_cache = PAGI::Headers->new([['Accept' => 'text/plain']]);
    my $source = {
        type                   => 'websocket',
        method                 => 'POST',
        path                   => '/chat',
        headers                => $headers,
        state                  => $nested,
        'pagi.request.headers' => $protocol_cache,
        'pagi.connection'      => PAGI::Test::ConnectionState->new(websocket => 1),
    };
    my @source_keys = sort keys %$source;

    isa_ok($application->response_for($source), ['PAGI::Response::Problem']);
    is($descriptor_count, 1, 'descriptor factory is called exactly once');
    is($Local::CountingPages::RESPONSE_COUNT, 1,
        'Pages policy is called exactly once');
    is($Local::CountingPages::NEGOTIATION_COUNT, 1,
        'renderer negotiation is called exactly once');
    is(refaddr($descriptor_scopes[0]), refaddr($source),
        'descriptor factory sees the original protocol scope');

    my $metadata = $Local::CountingPages::RESPONSE_SCOPES[0];
    is(refaddr($Local::CountingPages::NEGOTIATION_SCOPES[0]), refaddr($metadata),
        'renderer negotiation sees the policy metadata view');
    isnt(refaddr($metadata), refaddr($source),
        'protocol metadata uses a distinct top-level hash');
    is($metadata->{type}, 'websocket', 'metadata retains the real WebSocket type');
    is($metadata->{method}, 'POST', 'metadata retains the real method');
    is($metadata->{path}, '/chat', 'metadata retains the real path');
    is(refaddr($metadata->{headers}), refaddr($headers),
        'the repeated raw header list retains identity');
    is(refaddr($metadata->{state}), refaddr($nested),
        'other nested scope metadata retains identity');
    ok(!exists $metadata->{'pagi.request.headers'},
        'negotiation keeps its rebuilt request header cache private');

    is([sort keys %$source], \@source_keys, 'source keys are unchanged');
    is($source->{type}, 'websocket', 'source type is unchanged');
    is($source->{method}, 'POST', 'source method is unchanged');
    is($source->{path}, '/chat', 'source path is unchanged');
    is(refaddr($source->{'pagi.request.headers'}), refaddr($protocol_cache),
        'the original protocol header cache is unchanged');

    my $methodless = {
        type    => 'sse',
        headers => [],
        state   => $nested,
        'pagi.connection' => PAGI::Test::ConnectionState->new,
    };
    $application->response_for($methodless);
    my $methodless_metadata = $Local::CountingPages::RESPONSE_SCOPES[-1];
    ok(!exists $methodless_metadata->{method},
        'SSE metadata does not manufacture GET');
    ok(!exists $methodless_metadata->{path},
        'SSE metadata does not manufacture a path');
    is(refaddr($methodless_metadata->{state}), refaddr($nested),
        'shallow copying preserves nested reference identity');
};

subtest 'WebSocket and SSE caches are omitted only from isolated metadata views' => sub {
    local $Local::CountingPages::RESPONSE_COUNT = 0;
    local @Local::CountingPages::RESPONSE_SCOPES;

    my $policy = Local::CountingPages->new(as => 'auto', default => 'text');
    my $application = $policy->unauthorized(
        challenge => 'Bearer realm="api"',
    );
    my @accept = (
        'text/html;q=0.1',
        'application/problem+json;q=0.9',
    );
    my ($receive, $send) = callbacks();
    my @cases = (
        [websocket => sub {
            return PAGI::WebSocket->new(scope('websocket', headers => [
                ['Accept' => $accept[0]], ['Accept' => $accept[1]],
            ]), $receive, $send);
        }],
        [sse => sub {
            return PAGI::SSE->new(scope('sse', headers => [
                ['Accept' => $accept[0]], ['Accept' => $accept[1]],
            ]), $receive, $send);
        }],
    );

    for my $case (@cases) {
        my ($label, $factory) = @$case;
        my $object = $factory->();
        my $source = $object->scope;
        my $cache = $object->headers;
        isa_ok($cache, ['PAGI::Headers'], "$label builds its protocol cache first");
        my @source_keys = sort keys %$source;

        my $response = $application->response_for($object);
        isa_ok($response, ['PAGI::Response::Problem'],
            "$label raw repeated Accept lines negotiate problem JSON");
        is($response->content_type, 'application/problem+json',
            "$label selects the higher-quality repeated Accept representation");

        my $metadata = $Local::CountingPages::RESPONSE_SCOPES[-1];
        ok(!exists $metadata->{'pagi.request.headers'},
            "$label metadata does not receive the private HTTP cache");
        is($metadata->{headers}, [map { ['Accept' => $_] } @accept],
            "$label metadata retains both raw Accept lines");
        is(refaddr($source->{'pagi.request.headers'}), refaddr($cache),
            "$label source retains its original protocol cache");
        isa_ok($source->{'pagi.request.headers'}, ['PAGI::Headers'],
            "$label source cache class is not replaced");
        is([sort keys %$source], \@source_keys,
            "$label response materialization does not change source keys");
    }
};

subtest 'response_for and to_app share the same materializer' => sub {
    local $Local::CountingApplication::MATERIALIZE_COUNT = 0;
    my $descriptor_count = 0;
    my $application = Local::CountingApplication->new(
        policy             => PAGI::Pages->new(as => 'text'),
        descriptor_factory => sub {
            ++$descriptor_count;
            return problem_descriptor();
        },
    );

    isa_ok($application->response_for(scope('websocket')),
        ['PAGI::Response::Text'], 'response_for uses the shared materializer');
    is($Local::CountingApplication::MATERIALIZE_COUNT, 1,
        'response_for enters the materializer once');

    for my $type (qw(http websocket sse)) {
        my $events = invoke_application($application, scope($type));
        is($events->[0]{status}, 401,
            "to_app invokes the materialized response for $type");
    }
    is($Local::CountingApplication::MATERIALIZE_COUNT, 4,
        'each to_app invocation enters that same materializer once');
    is($descriptor_count, 4,
        'each entry point creates exactly one fresh descriptor');
};

done_testing;
