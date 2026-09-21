use v5.40;
use Future::AsyncAwait;
use PAGI::Auth qw(auth auth_result unauth_result);
use PAGI::Auth::SimpleUser;
use PAGI::Compose qw(compose);
use PAGI::Response qw(json_response);
use PAGI::Routing qw(route websocket sse middleware request_response);

my $refusal = request_response(sub ($request) {
    my $failure = auth($request)->failure;
    return json_response({ error => $failure->message }, status => 401);
});

compose(
    middleware => [middleware('Authentication', backend => sub ($request) {
        my $token = $request->bearer_token;
        return defined($token) && $token eq 'accepted'
            ? auth_result(user => PAGI::Auth::SimpleUser->new(identity => 'alice'))
            : unauth_result(failure => { message => 'An access token is required.' });
    })],
    routes => [
        route('/http' => sub ($request) {
            return $refusal unless auth($request)->user->is_authenticated;
            return json_response({ identity => auth($request)->user->identity });
        }),
        websocket('/socket' => async sub ($ws) {
            my $cleaned = 0;
            $ws->on_close(sub { ++$cleaned; return });
            unless (auth($ws)->user->is_authenticated) {
                await $ws->deny($refusal); # Before accept.
                return;
            }
            await $ws->accept;
            await $ws->close;
            die 'WebSocket cleanup did not run' unless $cleaned;
            return;
        }),
        sse('/events' => async sub ($stream) {
            my $cleaned = 0;
            $stream->on_close(sub { ++$cleaned; return });
            unless (auth($stream)->user->is_authenticated) {
                await $stream->decline($refusal); # Before start.
                return;
            }
            await $stream->start;
            await $stream->close;
            die 'SSE cleanup did not run' unless $cleaned;
            return;
        }),
    ],
);
