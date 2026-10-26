#!/usr/bin/env perl
#
# A webhook receiver, written in one sitting to see how fast a small
# PAGI-Tools application comes together: GitHub-style deliveries verified by
# HMAC over the raw body, appended to a JSONL log, with a status page and a
# JSON view of the log for whoever asked for the hook.
#
# Run:  WEBHOOK_SECRET=s3cret pagi-server --app examples/webhook-receiver/app.pl --port 5000
# Try:  body='{"action":"opened","number":7}'
#       sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac s3cret | sed 's/^.* //')
#       curl -i -X POST localhost:5000/hooks/github -H 'X-GitHub-Event: pull_request' \
#            -H "X-Hub-Signature-256: sha256=$sig" -H 'Content-Type: application/json' -d "$body"
#       curl -i -X POST localhost:5000/hooks/github -d "$body"     # 401: no signature
#       curl localhost:5000/                                         # the status page
#       curl localhost:5000/deliveries.json

use v5.40;
use Future::AsyncAwait;
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP ();
use PAGI::Tools qw(compose response route);

my $SECRET = $ENV{WEBHOOK_SECRET} // 's3cret';
my $LOG    = $ENV{WEBHOOK_LOG} // '/tmp/deliveries.jsonl';
my $JSON   = JSON::PP->new->canonical;

# The signature is over the bytes GitHub sent, so compare it against
# $request->body, not the parsed data. A constant-time compare keeps the
# secret from leaking by timing.
sub signature_ok ($request, $bytes) {
    my $given = $request->header('x-hub-signature-256');
    return 0 unless defined $given;
    my $want  = 'sha256=' . hmac_sha256_hex($bytes, $SECRET);
    return length($given) == length($want)
        && !(unpack('%32C*', $given ^. $want));
}

async sub receive ($request) {
    my $bytes = await $request->body;
    return response('JSON', { error => 'bad signature' }, status => 401)
        unless signature_ok($request, $bytes);

    my $payload  = await $request->json;    # a 400 if it is not JSON
    my $delivery = {
        id       => $request->header('x-github-delivery') // time,
        event    => $request->header('x-github-event') // 'unknown',
        received => time,
        payload  => $payload,
    };
    open my $fh, '>>', $LOG or die "open $LOG: $!";
    say {$fh} $JSON->encode($delivery);
    close $fh;

    return response('JSON', { ok => 1, id => $delivery->{id} }, status => 202);
}

sub deliveries () {
    open my $fh, '<', $LOG or return [];
    return [ map { $JSON->decode($_) } <$fh> ];
}

async sub status_page ($request) {
    my @recent = reverse @{ deliveries() }[-10 .. -1];
    my $rows = join '', map {
        sprintf '<li><code>%s</code> %s <small>%s</small></li>',
            $_->{event}, $_->{id}, scalar localtime $_->{received}
    } grep { defined } @recent;
    return response('HTML', <<~HTML);
        <h1>Webhook receiver</h1>
        <p>${\ scalar @{ deliveries() }} deliveries logged to <code>$LOG</code>.</p>
        <ul>$rows</ul>
        <p><a href="/deliveries.json">JSON</a></p>
        HTML
}

async sub deliveries_json ($request) {
    my $n = $request->query_param('n') // 50;
    my $all = deliveries();
    return response('JSON', [ @{$all}[ -($n < @$all ? $n : @$all) .. -1 ] ]);
}

compose(
    routes => [
        route('/hooks/github'     => \&receive, methods => ['POST']),
        route('/'                 => \&status_page),
        route('/deliveries.json'  => \&deliveries_json),
    ],
);
