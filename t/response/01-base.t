use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use PAGI::Response;

sub http_scope { { type => 'http', method => 'GET', headers => [] } }
sub receive { sub { Future->done({ type => 'http.request', body => '', more => 0 }) } }

{
    package T::InvalidSend;
    use overload '&{}' => sub {
        my ($self) = @_;
        return sub { $self->{calls}++; Future->done };
    }, fallback => 1;
    sub new { bless { calls => 0 }, shift }
    sub calls { $_[0]{calls} }
}

{
    package T::ConfiguredResponse;
    use Scalar::Util qw(refaddr);
    use parent -norequire, 'PAGI::Response';

    my %configured_status;

    sub new {
        my ($class, $body, $status, @pairs) = @_;
        my $self = $class->SUPER::new($body, @pairs);
        $configured_status{refaddr($self)} = $status;
        return $self;
    }

    sub configure_status {
        my ($self, $status) = @_;
        PAGI::Response::_validate_status($status);
        $configured_status{refaddr($self)} = 0 + $status;
        return $self;
    }

    sub replace_body {
        my ($self, $body) = @_;
        PAGI::Response::_require_bytes('configured response body', $body);
        $self->{_body} = $body;
        return $self;
    }

    sub status {
        my ($self, $status) = @_;
        return $self->SUPER::status($status) if @_ == 2;
        return $configured_status{refaddr($self)} // $self->SUPER::status;
    }
}

subtest 'base bytes retain metadata and byte invariants' => sub {
    my $bytes = "abc\x00";
    my $res = PAGI::Response->new(
        $bytes,
        status       => 201,
        content_type => 'application/octet-stream',
        headers      => ['X-One' => 'a', 'X-One' => 'b'],
    );

    is($res->body, $bytes, 'base response retains exact bytes');
    is($res->header_all('x-one'), ['a', 'b'], 'duplicate order retained');
    ok($res->is_buffered, 'base bytes are buffered');
    ok(!$res->can('scope'), 'Response is not a scope source');
    ok(!$res->can('cors'), 'CORS policy is not a Response method');
    like(dies { PAGI::Response->new(undef) }, qr/defined.*encoded bytes/i,
        'undefined body is rejected');
    like(dies { PAGI::Response->new([]) }, qr/unblessed scalar.*encoded bytes/i,
        'reference body is rejected');
    like(dies { PAGI::Response->new("wide \x{263a}") }, qr/encoded bytes/i);
    for my $forbidden (100, 204, 205, 304) {
        like dies { PAGI::Response->new('x', status => $forbidden) },
            qr/body.*\Q$forbidden\E/i, "body is rejected for status $forbidden";
    }
    my $utf8_ascii = 'ascii';
    utf8::upgrade($utf8_ascii);
    like(dies { PAGI::Response->new($utf8_ascii) }, qr/encoded bytes/i,
        'UTF-8-flagged ASCII is not accepted as bytes');
};

subtest 'constructor and metadata setters validate and preserve ordered semantics' => sub {
    my $res = PAGI::Response->new('x');
    is $res->status, 200, 'implicit status is 200';
    ok !$res->has_status, 'implicit status is not explicit';
    is $res->status_try(201), $res, 'status_try is chainable';
    is $res->status, 201, 'status_try sets an unset explicit status';
    is $res->status_try(202), $res, 'status_try remains chainable when set';
    is $res->status, 201, 'status_try does not replace status';
    like dies { $res->status(99) }, qr/100-599/i, 'status validates bounds';

    $res->header('X-Value' => 'first')->header('x-value' => 'second');
    is $res->header_all('X-Value'), ['first', 'second'], 'header appends in order';
    is $res->header('x-value'), 'second', 'header returns last value';
    ok $res->has_header('X-VALUE'), 'has_header folds case';
    $res->header_try('X-Value' => 'ignored');
    is $res->header_all('x-value'), ['first', 'second'],
        'header_try never appends to an existing multi-value field';
    $res->header_try('X-New' => 'kept');
    is $res->header_all('x-new'), ['kept'], 'header_try adds an absent field';
    $res->content_type('text/plain')->content_type('application/json');
    is $res->header_all('content-type'), ['application/json'],
        'content_type replaces rather than appends';
    $res->content_type_try('text/html');
    is $res->content_type, 'application/json', 'content_type_try does not replace';
    $res->remove_header('x-value');
    is $res->header_all('x-value'), [], 'remove_header clears every matching value';

    $res->cookie('session' => 'abc', path => '/', httponly => 1);
    like $res->header('set-cookie'), qr/session=abc/, 'cookie delegates formatting';
    $res->delete_cookie('session', path => '/');
    like $res->header('set-cookie'), qr/(?:Max-Age=0|expires=Thu, 01 Jan 1970)/i,
        'delete_cookie emits an expired cookie';

    like dies { PAGI::Response->new('x', unexpected => 1) }, qr/unknown response option/i,
        'unknown constructor option is rejected';
    like dies { PAGI::Response->new('x', status => 201, status => 202) }, qr/duplicate response option/i,
        'duplicate constructor option is rejected';
    like dies { PAGI::Response->new('x', 'status') }, qr/name.value pairs/i,
        'odd constructor option list is rejected';
    my $undefined_option_name;
    like dies { PAGI::Response->new('x', $undefined_option_name => 201) }, qr/option names.*scalar strings/i,
        'undefined constructor option name is rejected';
    like dies { PAGI::Response->new('x', [] => 201) }, qr/option names.*scalar strings/i,
        'reference constructor option name is rejected';
    like dies { PAGI::Response->new('x', headers => ['X-One']) }, qr/even-length/i,
        'flat headers require pairs';
    like dies { PAGI::Response->new('x', headers => [['X-One', 'one']]) }, qr/nested/i,
        'nested header pairs are rejected';
};

subtest 'Response application validates the full triplet, awaits each send, and protects framing' => sub {
    my $res = PAGI::Response->new('abc', headers => [
        'Content-Length' => '999', 'Transfer-Encoding' => 'chunked',
    ]);
    my @events;
    my $start = Future->new;
    my $body  = Future->new;
    my $calls = 0;
    my $send = sub {
        push @events, $_[0];
        return ++$calls == 1 ? $start : $body;
    };

    my $emission = $res->to_app->(http_scope(), receive(), $send);
    is scalar @events, 1, 'start event is sent first';
    ok !$emission->is_ready, 'pending start Future is awaited';
    $start->done;
    is scalar @events, 2, 'body is not sent until start resolves';
    ok !$emission->is_ready, 'pending body Future is awaited';
    $body->done;
    $emission->get;

    is $events[0]{headers}, [
        ['Content-Type' => 'application/octet-stream'], ['content-length' => 3],
    ], 'buffered emission removes TE and replaces Content-Length';
    is $events[1], { type => 'http.response.body', body => 'abc', more => 0 },
        'one terminal body event is sent';

    for my $bad (
        undef,
        {},
        { type => 'websocket' },
        { type => 'unknown' },
        bless({}, 'T::BlessedScope'),
    ) {
        my @bad_events;
        like dies { $res->to_app->($bad, receive(), sub { push @bad_events, $_[0]; Future->done })->get },
            qr/(?:scope|HTTP)/i, 'invalid scope is rejected';
        is \@bad_events, [], 'invalid scope sends no events';
    }
    my @bad_receive_events;
    like dies { $res->to_app->(http_scope(), 'receive', sub { push @bad_receive_events, $_[0]; Future->done })->get }, qr/receive.*coderef/i,
        'receive must be a coderef';
    is \@bad_receive_events, [], 'invalid receive sends no events';
    my $invalid_send = T::InvalidSend->new;
    like dies { $res->to_app->(http_scope(), receive(), $invalid_send)->get }, qr/send.*coderef/i,
        'send must be a coderef';
    is $invalid_send->calls, 0, 'invalid send records no events';
    like dies { $res->to_app->(sub { Future->done })->get }, qr/HTTP scope|scope hashref/i,
        'one-argument application invocation is rejected as an invalid scope';
};

subtest 'to_app retains the exact Response and each invocation captures one delivery plan' => sub {
    my $res = T::ConfiguredResponse->new(
        'first', 201, headers => ['X-Version' => 'first'],
    );
    my $app = $res->to_app;
    $res->configure_status(202)
        ->replace_body('second')
        ->remove_header('X-Version')
        ->header('X-Version' => 'second');

    my @first;
    my $first_start = Future->new;
    my $first_calls = 0;
    my $first_emission = $app->(
        http_scope(), receive(),
        sub {
            push @first, $_[0];
            return ++$first_calls == 1 ? $first_start : Future->done;
        },
    );
    is scalar @first, 1, 'the first invocation emits its captured start event';
    ok !$first_emission->is_ready, 'the first invocation awaits response start';

    $res->configure_status(203)
        ->replace_body('third')
        ->remove_header('X-Version')
        ->header('X-Version' => 'third');
    $first_start->done;
    $first_emission->get;
    is \@first, [
        {
            type    => 'http.response.start',
            status  => 202,
            headers => [
                ['Content-Type' => 'application/octet-stream'],
                ['X-Version' => 'second'],
                ['content-length' => 6],
            ],
        },
        { type => 'http.response.body', body => 'second', more => 0 },
    ], 'mutation while start is parked cannot split one start/body plan';

    my @second;
    $app->(
        http_scope(), receive(),
        sub { push @second, $_[0]; Future->done },
    )->get;
    is \@second, [
        {
            type    => 'http.response.start',
            status  => 203,
            headers => [
                ['Content-Type' => 'application/octet-stream'],
                ['X-Version' => 'third'],
                ['content-length' => 5],
            ],
        },
        { type => 'http.response.body', body => 'third', more => 0 },
    ], 'a later invocation observes later deliberate subclass and metadata changes';
};

{
    package T::RenderedResponse;
    use parent -norequire, 'PAGI::Response';
    sub default_content_type { 'application/x-rendered' }
    sub render {
        my ($self, $value) = @_;
        return "rendered:$value";
    }
}

subtest 'subclass hooks render bytes and default content type' => sub {
    my $res = T::RenderedResponse->new('value');
    is $res->body, 'rendered:value', 'render hook supplies byte body';
    is $res->content_type, 'application/x-rendered', 'default content type hook applies';
};

done_testing;
