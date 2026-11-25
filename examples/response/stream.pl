#!/usr/bin/env perl
# Responses written as they're made, with PAGI::Response::Stream:
#
#   /count      a line a second, then the end
#   /download   this file, relayed from a source, then its SHA-256 and
#               length as trailers
#   /events     NDJSON, one JSON object a line, with PAGI::Response::NDJSON
#   /feed       messages as they're published, until the client leaves
#   /feed-10s   the same, given up after ten seconds
#   /publish    sends the query string, as text, to everyone following the feed
#
#   pagi-server --app examples/response/stream.pl --port 5000
#   curl -N http://localhost:5000/count
#   curl --raw -i http://localhost:5000/download   # --raw shows the trailers
#   curl -N http://localhost:5000/events
#   curl -N http://localhost:5000/feed             # waits; leave with Ctrl-C
#   curl 'http://localhost:5000/publish?Gr%C3%BC%C3%9Fe%20%F0%9F%8C%8D'   # from another terminal: Grüße 🌍
#   curl -N http://localhost:5000/feed-10s
#
# How each stream ended is logged to the server's STDERR. Text goes out as
# UTF-8: write_text for characters, write for bytes you already have.

use v5.40;
use utf8;
use Future;
use Future::AsyncAwait;
use Future::IO;
use Encode ();
use PAGI::Response::Text;
use PAGI::Response::Stream;
use PAGI::Response::NDJSON;

# A file read a chunk at a time, keeping a SHA-256 and a count of what it
# has given: pipe_from relays it, and its trailers say what was sent.
package FileSource {
    use Digest::SHA ();

    sub new ($class, $path) {
        open my $fh, '<:raw', $path or die "can't read $path: $!\n";
        return bless { fh => $fh, sha => Digest::SHA->new(256), length => 0 }, $class;
    }

    sub next_chunk ($self) {
        my $read = sysread $self->{fh}, my $chunk, 4096;
        die "can't read: $!\n" unless defined $read;
        return undef unless $read;    # the end of the file
        $self->{sha}->add($chunk);
        $self->{length} += $read;
        return $chunk;
    }

    # Content-Digest (RFC 9530) is made to be sent as a trailer. The length
    # goes in a field of our own: Content-Length can't be a trailer.
    sub trailers ($self) {
        return [
            ['content-digest', 'sha-256=:' . $self->{sha}->b64digest . '=:'],
            ['x-body-length',  $self->{length}],
        ];
    }
}

# One feed for the whole application. Each client that follows it gets a
# subscription of its own, so a client leaving cancels only its own wait.
package Feed {
    use Scalar::Util ();

    sub new ($class) { return bless { subscriptions => {} }, $class }

    sub subscribe ($self) {
        my $subscription = Feed::Subscription->new;
        $self->{subscriptions}{ Scalar::Util::refaddr($subscription) } = $subscription;
        return $subscription;
    }

    sub unsubscribe ($self, $subscription) {
        delete $self->{subscriptions}{ Scalar::Util::refaddr($subscription) };
    }

    sub publish ($self, $message) {
        $_->deliver($message) for values %{ $self->{subscriptions} };
        return scalar keys %{ $self->{subscriptions} };
    }
}

package Feed::Subscription {
    sub new ($class) { return bless { queue => [], waiting => undef }, $class }

    # The next message: at once if one is queued, else a Future of its own.
    sub next ($self) {
        return Future->done(shift @{ $self->{queue} }) if @{ $self->{queue} };
        return $self->{waiting} = Future->new;
    }

    sub deliver ($self, $message) {
        my $waiting = delete $self->{waiting};
        return $waiting->done($message) if $waiting && !$waiting->is_ready;
        push @{ $self->{queue} }, $message;
    }
}

my $feed = Feed->new;

# Following the feed: the loop never ends by itself. When the client
# leaves, the body is cancelled at its await, and on_close unsubscribes.
sub follow_feed () {
    return PAGI::Response::Stream->new(
        content_type => 'text/plain; charset=utf-8',
        body         => async sub ($writer) {
            my $subscription = $feed->subscribe;
            $writer->on_close(sub ($writer) {
                $feed->unsubscribe($subscription);
                warn 'feed ended: ', $writer->outcome, "\n";
            });

            # A first line, so the client has the headers before any message.
            await $writer->write_text("Following the feed; publish with /publish?your-message\n");
            while (1) {
                my $message = await $subscription->next;
                await $writer->write_text("$message\n");    # characters, sent as UTF-8
            }
        },
    );
}

# The query string is bytes, percent-escaped: unescape it, then decode the
# UTF-8 to characters (a malformed byte becomes U+FFFD).
sub message_from ($query) {
    $query =~ tr/+/ /;
    $query =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    return Encode::decode('UTF-8', $query);
}

my $app = async sub ($scope, $receive, $send) {
    die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
    my $path = $scope->{path};

    if ($path eq '/feed-10s') {
        # To give up on a stream, end the connection: the body is cancelled
        # and on_close runs, as when the client leaves.
        my $timer = Future::IO->sleep(10)->on_done(sub {
            $scope->{'pagi.connection'}->abort('ten seconds are up');
        });
        await follow_feed()->call($scope, $receive, $send);
        $timer->cancel;
        return;
    }

    my $response;
    if ($path eq '/count') {
        $response = PAGI::Response::Stream->new(
            content_type => 'text/plain; charset=utf-8',
            body         => async sub ($writer) {
                for my $n (1 .. 3) {
                    await $writer->write_text("Line $n of 3 ✔\n");
                    await Future::IO->sleep(1);
                }
            },    # returning ends the stream
        );
    }
    elsif ($path eq '/download') {
        $response = PAGI::Response::Stream->new(
            content_type => 'text/plain; charset=utf-8',
            has_trailers => 1,
            body         => async sub ($writer) {
                my $file = FileSource->new(__FILE__);    # the request's own source
                await $writer->pipe_from($file);
                return $file->trailers;                  # sent after the body
            },
        );
    }
    elsif ($path eq '/events') {
        # Each item is one line of JSON: write_item encodes it.
        $response = PAGI::Response::NDJSON->new(body => async sub ($writer) {
            my $id = 0;
            for my $city ('Zürich', 'Kraków', 'São Paulo') {    # characters; NDJSON encodes
                await $writer->write_item({ id => ++$id, city => $city });
                await Future::IO->sleep(0.5);
            }
        });
    }
    elsif ($path eq '/feed') {
        $response = follow_feed();
    }
    elsif ($path eq '/publish') {
        my $message = message_from($scope->{query_string} // '');
        my $count = $feed->publish($message);
        $response = PAGI::Response::Text->new(content => "Published “$message” to $count follower(s)\n");
    }
    else {
        $response = PAGI::Response::Text->new(status => 404, content => "Not Found\n");
    }

    await $response->call($scope, $receive, $send);
};

$app;
