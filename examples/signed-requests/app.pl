#!/usr/bin/env perl
#
# Requests signed by a CI system, checked by a middleware: a build event
# read with $request->json, and a build artifact streamed to disk with
# body_stream. The middleware never reads the body itself. It hands the
# routes a receive that hashes each chunk as the route reads it and fails
# the read of the last one when the signature does not cover the body, the
# way Starlette's RequestBodyLimitMiddleware fails a read past its limit.
#
# The signature is an HMAC-SHA256, with the shared secret, of the body's
# SHA-256 (as AWS signs a payload's hash), so the middleware hashes the body
# as it arrives and never holds it in one string. The same application in
# Starlette is app.py.
#
# The check covers the body a route reads: a route under /signed that does
# not read its body, or stops reading early, is not checked. That is the
# price of checking without reading; to verify every request whether or not
# its route reads, read the whole body in the middleware first.
#
# Run:  SIGNING_SECRET=s3cret pagi-server --app examples/signed-requests/app.pl --port 5000
# Try:  sign() { openssl dgst -sha256 | sed 's/^.* //' | tr -d '\n' \
#                | openssl dgst -sha256 -hmac s3cret | sed 's/^.* /sha256=/'; }
#       body='{"build":42,"status":"passed"}'
#       curl -i localhost:5000/signed/events -H "X-Signature: $(printf '%s' "$body" | sign)" \
#            -H 'Content-Type: application/json' -d "$body"
#       head -c 5000000 /dev/urandom > build.tar
#       curl -i localhost:5000/signed/artifacts/build.tar -H "X-Signature: $(sign < build.tar)" \
#            --data-binary @build.tar
#       curl -i localhost:5000/signed/events -d "$body"     # 401: not signed
#       curl localhost:5000/events

use v5.40;
use Future::AsyncAwait;
use Digest::SHA ();
use File::Temp qw(tempdir);
use PAGI::Tools qw(compose middleware mount response route);

# The middleware's own failure. Not a PAGI::Exception::HTTP: an HTTP error a
# route raises is answered at the route, before the middleware could tell
# its own failure from the route's (app.py's BadSignature is not an
# HTTPException for the same reason).
package SignedRequests::BadSignature {
    sub throw ($class) { die bless {}, $class }
}

package SignedRequests::VerifySignature {
    use parent 'PAGI::Middleware';
    use Digest::SHA qw(hmac_sha256_hex);
    use PAGI::Tools qw(response);    # imports are per package; async is lexical, so only this one
    use PAGI::Utils::SecureCompare qw(secure_compare);

    sub _init ($self, $config) {
        $self->{secret} = $config->{secret} // die "VerifySignature needs a secret\n";
        $self->{refuse} = response('JSON', { error => 'bad signature' }, status => 401)->to_app;
    }

    sub wrap ($self, $app) {
        return async sub ($scope, $receive, $send) {
            return await $app->($scope, $receive, $send) unless $scope->{type} eq 'http';
            my ($given) = map { $_->[1] } grep { lc($_->[0]) eq 'x-signature' } @{$scope->{headers}};
            return await $self->{refuse}->($scope, $receive, $send) unless defined $given;

            # The routes' receive: each chunk is hashed as they read it, and
            # the last is handed over only if the signature covers the body.
            my $sha = Digest::SHA->new(256);
            my $verifying = async sub {
                my $event = await $receive->();
                return $event unless $event->{type} eq 'http.request';
                $sha->add($event->{body} // '');
                SignedRequests::BadSignature->throw
                    if !$event->{more}
                    && !secure_compare($given, 'sha256=' . hmac_sha256_hex($sha->hexdigest, $self->{secret}));
                return $event;
            };

            # Its own failed read is answered here when nothing was sent yet,
            # and rethrown otherwise; any other error passes through, as
            # Starlette's body limit catches only its own exception.
            my $started = 0;
            my $watching = async sub ($event) {
                $started = 1 if $event->{type} eq 'http.response.start';
                await $send->($event);
            };
            try { await $app->($scope, $verifying, $watching) }
            catch ($e) {
                die $e if $started || !($e isa SignedRequests::BadSignature);
                await $self->{refuse}->($scope, $receive, $send);
            }
        };
    }
}

my $SECRET = $ENV{SIGNING_SECRET} // 's3cret';

# A build event: read by PAGI::Request, through the verifying receive. The
# event is a JSON object; a JSON array is a 500 here, as in app.py.
async sub record_event ($request) {
    my $event = await $request->json;    # a 401 if unsigned, a 400 if not JSON
    push $request->state->get('events')->@*, $event;
    return response('JSON', { ok => 1, build => $event->{build} }, status => 202);
}

# A build artifact: streamed to a .part file and given its name only once
# the whole body was read, which is when the signature has been checked. A
# failed read leaves no file behind.
async sub store_artifact ($request) {
    my $path = $request->state->get('artifacts') . '/' . $request->path_param('name');
    my $body = $request->body_stream(max_bytes => 50 * 1024 * 1024);
    try { await $body->stream_to_file("$path.part") }
    catch ($e) {
        unlink "$path.part";
        die $e;
    }
    rename "$path.part", $path or die "rename $path.part: $!";
    my $sha = Digest::SHA->new(256)->addfile($path)->hexdigest;
    return response('JSON', { bytes => $body->bytes_read, sha256 => $sha }, status => 201);
}

compose(
    routes => [
        mount('/signed',
            routes => [
                route('/events' => \&record_event, methods => ['POST']),
                route('/artifacts/{name:[\w-]+(?:\.[\w-]+)*}' => \&store_artifact, methods => ['POST']),
            ],
            middleware => [middleware(SignedRequests::VerifySignature->new(secret => $SECRET))],
        ),
        route('/events' => sub ($request) { response('JSON', $request->state->get('events')) }),
    ],
    lifespan => {
        startup => sub ($state, $scope) {
            $state->{events}    = [];
            $state->{artifacts} = tempdir(CLEANUP => 1);
        },
    },
);
