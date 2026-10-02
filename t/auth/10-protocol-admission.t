use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr weaken);
use PAGI::Auth qw(auth auth_result unauth_result www_authenticate);
use PAGI::Auth::SimpleUser;
use PAGI::Compose qw(compose);
use PAGI::Middleware::Authentication;
use PAGI::Response qw(response);
use PAGI::Response::Stream;
use PAGI::Routing qw(route mount middleware websocket sse request_response);
use PAGI::Session qw(session);
use PAGI::Stash qw(stash);
use PAGI::State qw(app_state);
use PAGI::SSE;
use PAGI::WebSocket;
use PAGI::Test::Client;
use PAGI::Test::ConnectionState;
use PAGI::Test::Response;
use PAGI::Utils qw(as_app_object invoke_app);
use PAGI::Utils::Middleware qw(clone_scope);

{
    package Local::RefusalApp;
    sub new { my ($class, $app) = @_; return bless { app => $app }, $class }
    sub to_app { return $_[0]->{app} }
}

sub snapshot {
    my ($source) = @_;
    my $scope = ref($source) eq 'HASH' ? $source : $source->scope;
    my $context = auth($source);
    return {
        protocol => $scope->{type},
        identity => $context->user->identity,
        grants => [@{$context->credentials->scopes}],
        failure => $context->failure ? $context->failure->code : undef,
    };
}

subtest 'mounted Auth retains real protocol scopes and ordinary refusal applications' => sub {
    for my $form (qw(sync_request async_request object native)) {
        subtest $form => sub {
            my (@events, @backend_types, @handler_contexts, @refusal_contexts);
            my $closed = 0;
            my $shared = { state => {}, stash => {}, session => {} };
            my $observe_shared = sub {
                my ($source) = @_;
                is refaddr(app_state($source)->get('shared')), refaddr($shared->{state}),
                    'existing application state reference survives';
                is refaddr(stash($source)->get('shared')), refaddr($shared->{stash}),
                    'existing stash reference survives';
                is refaddr(session($source)->get('shared')), refaddr($shared->{session}),
                    'existing session reference survives';
            };
            my $response_for = sub {
                my ($source) = @_;
                $observe_shared->($source);
                push @refusal_contexts, snapshot($source);
                return response('JSON', { error => 'Sign in', %{snapshot($source)} },
                    status => 401,
                    headers => [
                        'WWW-Authenticate' => www_authenticate('Basic', realm => 'staff'),
                        'WWW-Authenticate' => www_authenticate('Bearer', realm => 'api'),
                        'X-Application' => 'chosen-response',
                    ]);
            };
            my $native = async sub {
                my ($scope, $receive, $send) = @_;
                await invoke_app($response_for->($scope), $scope, $receive, $send);
                return;
            };
            my $refusal = $form eq 'sync_request' ? sub {
                isa_ok $_[0], 'PAGI::Request';
                return $response_for->($_[0]);
            } : $form eq 'async_request' ? async sub {
                isa_ok $_[0], 'PAGI::Request';
                return $response_for->($_[0]);
            } : $form eq 'object' ? Local::RefusalApp->new($native)
                : as_app_object($native);
            # Returned HTTP application coderefs are native; mark a returned
            # Request handler explicitly. deny/decline adapt their handlers.
            my $http_refusal = ref($refusal) eq 'CODE'
                ? request_response($refusal) : $refusal;
            my $check = sub {
                my ($source) = @_;
                $observe_shared->($source);
                push @handler_contexts, snapshot($source);
                return auth($source)->user->is_authenticated;
            };
            my $application = compose(
                middleware => [middleware('Authentication', backend => sub {
                    my ($request) = @_;
                    isa_ok $request, 'PAGI::Request';
                    push @backend_types, $request->scope->{type};
                    $observe_shared->($request);
                    my $token = $request->header('authorization') // '';
                    return auth_result(user => PAGI::Auth::SimpleUser->new(identity => 'alice'))
                        if $token eq 'Bearer accepted';
                    return unauth_result(scopes => ['notes:read']) if $token eq 'Bearer guest';
                    return unauth_result(failure => { message => 'Rejected', code => 'bad_token' })
                        if length $token;
                    return unauth_result();
                })],
                routes => [
                    route('/http' => sub {
                        my ($request) = @_;
                        return $http_refusal unless $check->($request);
                        return response('JSON', { accepted => snapshot($request) });
                    }),
                    websocket('/socket' => async sub {
                        my ($ws) = @_;
                        $ws->on_close(sub { ++$closed; return });
                        unless ($check->($ws)) {
                            await $ws->deny($refusal);
                            return;
                        }
                        await $ws->accept;
                        await $ws->close;
                        return;
                    }),
                    sse('/events' => async sub {
                        my ($stream) = @_;
                        $stream->on_close(sub { ++$closed; return });
                        unless ($check->($stream)) {
                            await $stream->decline($refusal);
                            return;
                        }
                        await $stream->start;
                        await $stream->close;
                        return;
                    }),
                ],
            );
            # These references already exist before authentication. No route
            # parameters or later helper allocations are assumed at this point.
            my $setup = sub {
                my ($next) = @_;
                return async sub {
                    my ($scope, $receive, $send) = @_;
                    my $inner = clone_scope($scope, {
                        state => { shared => $shared->{state} },
                        'pagi.stash' => { shared => $shared->{stash} },
                        'pagi.session' => { shared => $shared->{session} },
                    });
                    await invoke_app($next, $inner, $receive, sub {
                        push @events, $_[0];
                        return $send->($_[0]);
                    });
                    return;
                };
            };
            my $client = PAGI::Test::Client->new(app => compose(
                middleware => [middleware($setup)],
                routes => [mount('/private', app => $application)],
            ));
            for my $protocol (qw(http websocket sse)) {
                for my $mode (qw(missing rejected guest accepted)) {
                    @events = ();
                    @refusal_contexts = ();
                    my $closed_before = $closed;
                    my %options = (headers => $mode eq 'missing'
                        ? {} : { Authorization => "Bearer $mode" });
                    my $response = $protocol eq 'http' ? $client->get('/private/http', %options)
                        : $protocol eq 'websocket' ? $client->websocket('/private/socket', %options)
                        : $client->sse('/private/events', %options);
                    my $expected = {
                        protocol => $protocol,
                        identity => $mode eq 'accepted' ? 'alice' : '',
                        grants => $mode eq 'guest' ? ['notes:read'] : [],
                        failure => $mode eq 'rejected' ? 'bad_token' : undef,
                    };
                    is $backend_types[-1], $protocol, "$mode backend receives original $protocol type";
                    is $handler_contexts[-1], $expected,
                        "$mode $protocol helper observes the complete context";
                    if ($mode eq 'accepted') {
                        is \@refusal_contexts, [], 'authenticated user with no grants bypasses refusal';
                        if ($protocol eq 'http') {
                            is $response->status, 200, 'HTTP accepts';
                            is $response->json, { accepted => $expected }, 'accepted response is unchanged';
                        } else {
                            is [map { $_->{type} } @events], [
                                $protocol eq 'websocket' ? 'websocket.accept' : 'sse.start',
                                "$protocol.close",
                            ], 'normal admission precedes close';
                            ok $response->is_closed, 'accepted connection closes normally';
                        }
                    } else {
                        is \@refusal_contexts, [$expected], 'selected refusal observes original context';
                        if ($protocol eq 'websocket') {
                            ok $response->is_closed, 'denied socket is terminal';
                            $response = PAGI::Test::Response->new(events => \@events);
                        }
                        isa_ok $response, 'PAGI::Test::Response';
                        is $response->status, 401, 'application explicitly refuses with 401';
                        is $response->json, { error => 'Sign in', %$expected },
                            'selected application body remains unchanged';
                        is $response->header_all('WWW-Authenticate'), [
                            'Basic realm="staff"', 'Bearer realm="api"',
                        ], 'repeated challenge headers remain distinct and ordered';
                        is $response->header('X-Application'), 'chosen-response',
                            'custom application header remains unchanged';
                        is [map { $_->{type} } @events], [qw(http.response.start http.response.body)],
                            'refusal emits no WebSocket acceptance or SSE start';
                    }
                    is $closed - $closed_before, $protocol eq 'http' ? 0 : 1,
                        'protocol terminal cleanup runs exactly once';
                }
            }
        };
    }
};

subtest 'parked refusal producers retain existing terminal cleanup through Authentication' => sub {
    for my $type (qw(websocket sse)) {
        subtest $type => sub {
            my $connection = PAGI::Test::ConnectionState->new(websocket => $type eq 'websocket');
            my (@sent, $weak_writer, $weak_producer);
            my ($cancelled, $writer_cleanup, $helper_cleanup, $finished) = (0, 0, 0, 0);
            my $middleware = PAGI::Middleware::Authentication->new(backend => sub {
                return unauth_result(failure => { message => 'Sign in', code => 'rejected' });
            });
            my $app = $middleware->wrap(async sub {
                my ($scope, $receive, $send) = @_;
                my $class = $type eq 'websocket' ? 'PAGI::WebSocket' : 'PAGI::SSE';
                my $protocol = $class->new($scope, $receive, $send);
                is auth($protocol)->failure->code, 'rejected', 'refusal sees installed Auth failure';
                $protocol->on_close(sub { ++$helper_cleanup; return });
                my $response = PAGI::Response::Stream->new(sub {
                    my ($writer) = @_;
                    $weak_writer = $writer; weaken($weak_writer);
                    $writer->on_close(sub { ++$writer_cleanup; return });
                    my $producer = (async sub {
                        await $writer->write('parked');
                        await Future->new;
                    })->();
                    $weak_producer = $producer; weaken($weak_producer);
                    $producer->on_cancel(sub { ++$cancelled; return });
                    return $producer;
                }, status => 401, headers => ['WWW-Authenticate' => www_authenticate('Bearer')]);
                if ($type eq 'websocket') { await $protocol->deny($response) }
                else { await $protocol->decline($response) }
                ++$finished;
                return;
            });
            my $running = $app->({
                type => $type, method => 'GET', headers => [], path => '/',
                'pagi.connection' => $connection,
            }, sub {
                return Future->done($type eq 'websocket'
                    ? { type => 'websocket.connect' }
                    : { type => 'sse.request', body => '', more => 0 });
            }, sub {
                push @sent, $_[0]->{type};
                return Future->done;
            });
            ok !$running->is_ready, 'middleware remains attached to parked refusal';
            ok $weak_writer && $weak_producer, 'producer resources live until terminal outcome';
            # Test connection driver supplies the existing public terminal facts.
            $connection->_mark_disconnected('client_closed');
            ok lives { $running->get }, 'ordinary terminal handling settles middleware successfully';
            is [$cancelled, $writer_cleanup, $helper_cleanup, $finished], [1, 1, 1, 1],
                'existing producer cancellation and cleanup each happen once';
            ok !$weak_writer && !$weak_producer, 'producer and writer are released';
            is \@sent, [qw(http.response.start http.response.body)],
                'terminal outcome causes no late send or protocol admission';
        };
    }
};

done_testing;
