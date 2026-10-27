package RawApp::Send;

# The protocol events RawApp sends more than once, written once: reading a
# request body to its end, and a complete text response.

use v5.40;
use Exporter 'import';
use Encode qw(encode);
use Future::AsyncAwait;

our @EXPORT_OK = qw(drain_body send_text);

# Reads the request body to its end. RawApp has no use for one, but a client
# that sends it is answered only after it has been read.
async sub drain_body ($receive) {
    while (1) {
        my $event = await $receive->();
        return if $event->{type} ne 'http.request' || !$event->{more};
    }
}

# A whole text/plain response: the start event, then the body as UTF-8 bytes
# (a body is bytes, never characters). Any extra headers are [name, value]
# pairs. Sent before websocket.accept or sse.start, it refuses the connection.
async sub send_text ($send, $status, $text, @headers) {
    my $body = encode('UTF-8', $text);
    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [['content-type', 'text/plain; charset=utf-8'], ['content-length', length $body], @headers],
    });
    await $send->({ type => 'http.response.body', body => $body, more => 0 });
}

1;
