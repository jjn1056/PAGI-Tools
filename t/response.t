use v5.24;
use warnings;
use Test2::V0;
use Future;
use PAGI::Test::Client;
use PAGI::Test::ConnectionState;
use Test::Lib;
use PAGITest::LowercaseHeaders;

use PAGI::Response;

# Serves a response for one GET, as a strict server would.
sub get { PAGI::Test::Client->new(app => $_[0])->get('/') }

# The headers the response sent: all but the Date the client adds, as a server does.
sub sent_headers { [grep { $_->[0] ne 'date' } @{ $_[0]->header_pairs }] }

# A $send that records each event with the Future it returned, which the
# test settles: a server that takes its time.
sub recording_send {
    my @sent;
    return (sub { push @sent, { event => $_[0], future => Future->new }; $sent[-1]{future} }, \@sent);
}

# Calls a response with a recording $send, and anything more for the scope;
# returns call's Future and what was sent.
sub call_recorded {
    my ($response, %scope) = @_;
    my ($send, $sent) = recording_send();
    my $call = $response->call({ type => 'http', method => 'GET', %scope }, sub { Future->new }, $send);
    return ($call, $sent);
}

subtest 'bytes: the start, then the body' => sub {
    my $response = PAGI::Response->new(content => 'abc');
    my $res = get($response);
    is $res->status, 200, 'status 200';
    is $res->content, 'abc', 'the body';
    is sent_headers($res), [['content-length', 3]], 'the length worked out; no type, since none was given';
    is get($response)->content, 'abc', 'served again: the same';
    is(PAGI::Response->new(content => 'abc')->body, 'abc', 'content by name');
};

subtest 'content goes by name only' => sub {
    like(dies { PAGI::Response->new('abc') }, qr/odd number/, "positional content: Class::Tiny's odd-arguments error");
    is(PAGI::Response->new(content => 'abc')->body, 'abc', 'by name');
};

subtest 'no content' => sub {
    my $res = get(PAGI::Response->new);
    is $res->content, '', 'an empty body';
    is sent_headers($res), [['content-length', 0]], 'length 0, no type';
    is(PAGI::Response->new(content => undef)->body, '', 'undef is no content');
};

subtest 'content-length: the body\'s, except on 204 and 304' => sub {
    is sent_headers(get(PAGI::Response->new(content => 'hello'))), [['content-length', 5]], 'the body\'s length in bytes';
    for my $status (204, 304) {
        my $res = get(PAGI::Response->new(status => $status));
        is $res->status, $status, "$status served";
        is sent_headers($res), [], "$status: no headers";
    }
    is get(PAGI::Response->new(status => 205))->header('content-length'), 0, '205: its body is empty';
    is sent_headers(get(PAGI::Response->new(content => 'hello', headers => [['Content-Length', 5]]))), [['content-length', 5]],
        'one you give is sent, and no other added';
};

subtest 'content_type: yours, else the class default, on every status' => sub {
    is sent_headers(get(PAGI::Response->new(content => 'x'))), [['content-length', 1]], 'the base has no default: none sent';
    for my $status (204, 304) {
        is(PAGI::Response->new(content => 'abc', status => $status)->headers, [], "$status: no type, no length");
    }
    is(PAGI::Response->new(status => 204, content_type => 'text/plain')->headers, [['content-type', 'text/plain']],
        'a content_type you give is sent on a 204');
    is(PAGI::Response->new(status => 304, headers => [['Content-Type', 'image/png']])->headers, [['content-type', 'image/png']],
        'and a content-type header on a 304');
    is(Local::CSV->new(status => 204)->headers, [['content-type', 'text/csv']], "and a class's default on a 204");
    is(PAGI::Response->new(content => 'abc', status => 205)->headers, [['content-length', 3]], '205: its length');
};

subtest 'immutable: read, never written' => sub {
    my $res = PAGI::Response->new(content => 'abc', status => 201, headers => [['X-Id', 7]], content_type => 'text/csv');
    is $res->status, 201, 'status';
    is $res->headers, [['x-id', 7], ['content-length', 3], ['content-type', 'text/csv']],
        'headers: yours, lowercased, then the derived ones -- what the start sends';
    ok !$res->can('start_headers'), 'one list, not two';
    is $res->content_type, 'text/csv', 'content_type';
    is $res->body, 'abc', 'body';
    ok !$res->has_trailers, 'has_trailers';
    for my $name (qw(status headers content_type body has_trailers)) {
        like(dies { $res->$name(1) }, qr/\Aresponse is immutable: \$response->$name can't be set; build a new response/, "$name can't be set");
    }
    is $res->status, 201, 'and nothing changed';
    like(dies { Local::CSV->new(content => [[1]])->status(204) }, qr/\Aresponse is immutable: \$response->status can't be set/,
        'in a subclass too');
    is(PAGI::Response->new(content => 'abc')->content_type, undef, 'content_type: none when none was given');
};

subtest 'what you gave new is copied' => sub {
    my $given = [['x-id', 7]];
    my $built = PAGI::Response->new(content => 'abc', headers => $given);
    push @$given, ['x-leak', 1];
    $given->[0][1] = 'changed';
    is $built->headers, [['x-id', 7], ['content-length', 3]], 'changing your list later changes nothing';
};

subtest 'headers: yours, lowercased, and they win' => sub {
    my $given = [['X-One', 'a'], ['X-One-Two', 'b']];
    my $res = get(PAGI::Response->new(content => 'abc', headers => $given));
    is sent_headers($res), [['x-one', 'a'], ['x-one-two', 'b'], ['content-length', 3]], 'names lowercased, then the length';
    is $given, [['X-One', 'a'], ['X-One-Two', 'b']], 'yours are untouched';
    is sent_headers(get(PAGI::Response->new(content => 'abc', headers => [['Content-Type', 'image/png'], ['Content-Length', 3]], content_type => 'x/y'))),
        [['content-type', 'image/png'], ['content-length', 3]], 'a content-type or content-length you give is the one sent';
    my $typed = get(PAGI::Response->new(content => 'abc', content_type => 'image/png', status => 201));
    is $typed->status, 201, 'status';
    is $typed->content_type, 'image/png', 'content_type';
};

subtest 'a middleware that edits the start in place changes only that request' => sub {
    my $response = PAGI::Response->new(content => 'abc');
    my $edits = sub {
        my ($scope, $receive, $send) = @_;
        $response->call($scope, $receive, sub {
            my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                push @{ $event->{headers} }, ['x-request-id', 1];
                $event->{headers}[0][1] = 'x';
            }
            $send->($event);
        });
    };
    get($edits) for 1, 2;
    is sent_headers(get($response)), [['content-length', 3]], 'the response is unchanged';
};

subtest 'bytes 128-255 pass through unchanged (CONTRIBUTING.md)' => sub {
    for my $byte ("\x85", "\xA0", "\xC3\xA0", "\xC9") {
        my $res = get(PAGI::Response->new(content => "a${byte}b", headers => [['X-B', "v${byte}w"]]));
        is sent_headers($res), [['x-b', "v${byte}w"], ['content-length', length "a${byte}b"]],
            sprintf('%vX: the value is untouched, the length counts bytes', $byte);
        is $res->content, "a${byte}b", sprintf('%vX: the content is unchanged', $byte);
    }
};

subtest 'content must be bytes: the send says so, as a server would' => sub {
    like get(PAGI::Response->new(content => "caf\x{e9} \x{263A}"))->exception, qr/contains a character above 0xFF/, 'a character above 0xFF';
    like get(PAGI::Response->new(content => [1]))->exception, qr/must be bytes, not a ARRAY reference/, 'a reference';
    is get(PAGI::Response->new(content => "caf\xE9"))->content, "caf\xE9", 'bytes 128-255 are bytes';
};

package Local::Steps { use parent -norequire, 'PAGI::Response';
    sub prepare_content_type { my ($self, $args) = @_; return $args->{format} // 'text/csv' } }
package Local::Moved { use parent -norequire, 'PAGI::Response';
    sub prepare_status { my ($self, $args) = @_; return $args->{status} // 302 } }
package Local::Located { use parent -norequire, 'PAGI::Response';
    sub prepare_headers { my ($self, $args, %prepared) = @_;
        my $headers = $self->SUPER::prepare_headers($args, %prepared);
        push @$headers, ['location', $args->{location}];
        return $headers } }
package Local::Given { use parent -norequire, 'PAGI::Response';
    sub prepare_content_type { my ($self, $args, %prepared) = @_; $Local::Given::TYPE_GOT = {%prepared};
        return $prepared{body} =~ /\A\{/ ? 'application/json' : 'text/plain' }
    sub prepare_headers { my ($self, $args, %prepared) = @_; $Local::Given::HEADERS_GOT = {%prepared};
        return $self->SUPER::prepare_headers($args, %prepared) } }
package Local::CSV { use parent -norequire, 'PAGI::Response';
    sub default_content_type { 'text/csv' }
    sub render { my ($self, $rows) = @_; join '', map { join(',', @$_) . "\r\n" } @$rows } }
package main;

subtest 'prepare: a subclass adds its own arguments' => sub {
    my $res = Local::Located->new(status => 302, location => '/there', headers => [['X-Id', 7]]);
    is $res->headers, [['x-id', 7], ['content-length', 0], ['location', '/there']], 'prepare_headers extended: the list, then its own';
    is $res->status, 302, 'and the rest prepared as usual';
    is(Local::Moved->new->status, 302, 'prepare_status extended: its own default');
    is(Local::Moved->new(status => 301)->status, 301, 'and yours wins');
    is(Local::Steps->new(content => 'abc')->content_type, 'text/csv', 'prepare_content_type extended');
    ok !PAGI::Response->can($_), "no $_ step" for qw(prepare_has_trailers prepare_cookies);
};

subtest 'each step is given what it depends on' => sub {
    my $res = Local::Given->new(content => '{"a":1}', status => 201);
    is $Local::Given::TYPE_GOT, { status => 201, body => '{"a":1}' }, 'prepare_content_type: the status and the body';
    is $res->content_type, 'application/json', 'and decides from them';
    is $Local::Given::HEADERS_GOT, { status => 201, body => '{"a":1}', content_type => 'application/json' },
        'prepare_headers: everything it is worked out from';
};

subtest 'default_content_type: the class type, no arguments' => sub {
    is(PAGI::Response->default_content_type, undef, 'the base: none');
    is(Local::CSV->default_content_type, 'text/csv', 'a format: its own');
};

subtest 'prepare: content_type as given' => sub {
    is(PAGI::Response->new(content => 'abc', content_type => 'image/png')->content_type, 'image/png', 'content_type');
    is(PAGI::Response->new(content => 'abc', content_type => undef)->headers, [['content-length', 3]], 'content_type undef: none sent');
};

subtest 'call: the start, then the body as one event, once the start has gone' => sub {
    my ($call, $sent) = call_recorded(PAGI::Response->new(content => 'abc', headers => [['x-id', 7]]));
    is [map { $_->{event}{type} } @$sent], ['http.response.start'], 'the start, and the body waits for its send';
    is $sent->[0]{event}{headers}, [['x-id', 7], ['content-length', 3]], 'the start carries the headers';
    $sent->[0]{future}->done;
    is $sent->[1]{event}, { type => 'http.response.body', body => 'abc', more => 0 }, 'then one body event, the last';
    is scalar @$sent, 2, 'and nothing else';
    ok !$call->is_ready, 'call waits for the body send';
    $sent->[1]{future}->done;
    ok $call->is_done, 'and is done once it has gone';
    is [$call->get], [], 'with nothing';
    ok !PAGI::Response->can($_), "no $_" for qw(send_body send_trailers);
    can_ok 'PAGI::Response', 'send_start';
};

subtest 'call: on a 204 the content is sent as given' => sub {
    my ($call, $sent) = call_recorded(PAGI::Response->new(content => 'abc', status => 204));
    $sent->[0]{future}->done;
    is $sent->[1]{event}{body}, 'abc', 'the server discards it, not the response';
};

subtest 'call: a send that fails fails call, with its error' => sub {
    my ($call, $sent) = call_recorded(PAGI::Response->new(content => 'abc'));
    $sent->[0]{future}->fail("start refused\n", 'pagi', 1);
    is [$call->failure], ["start refused\n", 'pagi', 1], 'the start failed: its error';
    is scalar @$sent, 1, 'and no body is sent';
    ($call, $sent) = call_recorded(PAGI::Response->new(content => 'abc'));
    $sent->[0]{future}->done;
    $sent->[1]{future}->fail("body refused\n");
    is $call->failure, "body refused\n", 'the body failed: its error';
    ($call, $sent) = call_recorded(PAGI::Response->new(content => 'abc'));
    $sent->[0]{future}->cancel;
    like $call->failure, qr/\Athe start's send was cancelled/, 'a send cancelled by someone else fails call';
    is scalar @$sent, 1, 'and nothing more is sent';
    my $dies = PAGI::Response->new(content => 'abc')->call({ type => 'http', method => 'GET' }, sub { Future->new },
        sub { die "no send\n" });
    is $dies->failure, "no send\n", 'a $send that dies: call fails with that';
};

subtest 'call cancelled by its caller: the connection is aborted, and no body follows' => sub {
    my $connection = PAGI::Test::ConnectionState->new;
    my ($call, $sent) = call_recorded(PAGI::Response->new(content => 'abc'), 'pagi.connection' => $connection);
    $call->cancel;
    is $connection->disconnect_reason, 'app_abort', 'the connection is aborted';
    is $connection->disconnect_detail, 'response cancelled by caller', 'saying why';
    $sent->[0]{future}->done;
    is scalar @$sent, 1, 'the start resolving afterwards sends no body';
    $connection = PAGI::Test::ConnectionState->new;
    ($call, $sent) = call_recorded(PAGI::Response->new(content => 'abc'), 'pagi.connection' => $connection);
    $sent->[0]{future}->done;
    $call->cancel;
    is $connection->disconnect_reason, 'app_abort', 'cancelled while the body is going: aborted too';
    ($call, $sent) = call_recorded(PAGI::Response->new(content => 'abc'));
    ok lives { $call->cancel; $sent->[0]{future}->done }, 'no pagi.connection: nothing dies';
    is scalar @$sent, 1, 'and no body is sent';
};

subtest 'call cancelled: a send settling afterwards changes nothing' => sub {
    for my $settle ([done => sub { $_[0]->done }], [failed => sub { $_[0]->fail("cut\n") }]) {
        my ($how, $settles) = @$settle;
        my ($call, $sent) = call_recorded(PAGI::Response->new(content => 'abc'),
            'pagi.connection' => PAGI::Test::ConnectionState->new);
        $sent->[0]{future}->done;
        $call->cancel;
        is warnings { ok lives { $settles->($sent->[1]{future}) }, "the body's send $how afterwards: nothing dies" }, [],
            'and nothing warns';
        ok $call->is_cancelled, 'call stays cancelled';
    }
    for my $pending (qw(start body)) {
        my $send_of;
        my $connection = PAGI::Test::ConnectionState->new(on_abort => sub { $send_of->()->fail("aborted\n") });
        my ($call, $sent) = call_recorded(PAGI::Response->new(content => 'abc'), 'pagi.connection' => $connection);
        $sent->[0]{future}->done if $pending eq 'body';
        $send_of = sub { $sent->[-1]{future} };
        is warnings { ok lives { $call->cancel }, "the abort fails the pending $pending send: nothing dies" }, [],
            'and nothing warns';
        ok $call->is_cancelled, 'call is cancelled';
        is scalar @$sent, $pending eq 'body' ? 2 : 1, 'and nothing more is sent';
    }
};

subtest 'call: its Future is its own; cancelling it cancels neither send' => sub {
    my ($call, $sent) = call_recorded(PAGI::Response->new(content => 'abc'));
    $call->cancel;
    ok !$sent->[0]{future}->is_cancelled, 'the start\'s send is not cancelled';
    ($call, $sent) = call_recorded(PAGI::Response->new(content => 'abc'));
    $sent->[0]{future}->done;
    $call->cancel;
    ok !$sent->[1]{future}->is_cancelled, 'nor the body\'s';
};

subtest 'a format of your own' => sub {
    my $res = get(Local::CSV->new(content => [[1, 2], [3, 4]]));
    is $res->content, "1,2\r\n3,4\r\n", 'render';
    is $res->content_type, 'text/csv', 'its type';
};

subtest 'has_trailers: a buffered response declares none' => sub {
    my $res = PAGI::Response->new(content => 'abc', has_trailers => 1);
    ok !$res->has_trailers, 'has_trailers => 1 is ignored, not refused: always false here';
    my @sent;
    $res->call({ type => 'http', method => 'GET' }, sub { Future->new }, sub { push @sent, $_[0]; Future->done })->get;
    ok !exists $sent[0]{trailers}, 'the start declares no trailers';
    my $served = get($res);
    is $served->header('content-length'), 3, 'so it has its length';
    is $served->trailer_pairs, [], 'and no trailers are sent';
    ok !PAGI::Response->can('trailers_for'), 'no per-request trailers hook';
};

done_testing;
