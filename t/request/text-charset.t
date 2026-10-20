use strict;
use warnings;
use utf8;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use PAGI::Request;

# text decodes the body with the charset the client declared in Content-Type,
# and with UTF-8 when it declared none.

sub text_of {
    my ($body, $content_type, %opts) = @_;
    my $sent = 0;
    my $receive = sub {
        return Future->done({ type => 'http.disconnect' }) if $sent++;
        return Future->done({ type => 'http.request', body => $body, more => 0 });
    };
    my $request = PAGI::Request->new({
        type => 'http', method => 'POST',
        headers => [defined $content_type ? ['content-type', $content_type] : ()],
    }, $receive);
    return (async sub { await $request->text(%opts) })->()->get;
}

is(text_of("caf\xC3\xA9", 'text/plain'), 'café', 'UTF-8 when no charset is declared');
is(text_of("caf\xC3\xA9", undef), 'café', 'and without a Content-Type');
is(text_of("caf\xE9", 'text/plain; charset=ISO-8859-1'), 'café', 'the declared charset otherwise');
is(text_of("c\0a\0f\0\xE9\0", 'text/plain; charset=UTF-16LE'), 'café', 'a multi-byte one too');
is(text_of("caf\xC3\xA9", 'text/plain; charset="utf-8"'), 'café', 'a quoted name, in any case');
is(text_of("caf\xE9", 'text/plain; charset=ISO-8859-1', strict => 1), 'café',
    'strict accepts what is valid in the declared charset');

my $error = dies { text_of("caf\xE9", 'text/plain; charset=US-ASCII', strict => 1) };
isa_ok($error, 'PAGI::Exception::RequestBody');
is([$error->status_code, $error->reason, $error->message],
    [400, 'invalid_encoding', 'The request body is not valid US-ASCII.'],
    'strict rejects what is invalid in it, naming the charset');

# The same, with the body arriving as two events: text reads it whole, so a
# strict UTF-16 body split mid-character is fine.
sub text_of_events {
    my ($content_type, @bodies) = @_;
    my @events = map { { type => 'http.request', body => $bodies[$_], more => ($_ < $#bodies ? 1 : 0) } } 0 .. $#bodies;
    my $receive = sub { Future->done(shift(@events) // { type => 'http.disconnect' }) };
    my $request = PAGI::Request->new({
        type => 'http', method => 'POST', headers => [['content-type', $content_type]],
    }, $receive);
    return (async sub { await $request->text(strict => 1) })->()->get;
}
is(text_of_events('text/plain; charset=UTF-16', "\xFF\xFEh\0i", "\0!\0"), 'hi!',
    'strict UTF-16 across two events');


# A charset body_stream cannot decode in chunks is its 415; the body has not
# been touched, so text can still read it whole.
{
    my $sent = 0;
    my $receive = sub {
        return Future->done({ type => 'http.disconnect' }) if $sent++;
        return Future->done({ type => 'http.request', body => "\e\$B\$\"\e(B", more => 0 });
    };
    my $request = PAGI::Request->new({
        type => 'http', method => 'POST', headers => [['content-type', 'text/plain; charset=ISO-2022-JP']],
    }, $receive);
    my $error = dies { $request->body_stream(decode => $request->charset, strict => 1) };
    is($error && $error->status_code, 415, 'body_stream refuses a charset it cannot stream');
    is((async sub { await $request->text(strict => 1) })->()->get, "\x{3042}", 'and text reads the body whole');
}

done_testing;
