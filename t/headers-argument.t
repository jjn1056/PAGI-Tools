use strict;
use warnings;
use Test2::V0;
use Encode ();

use lib 't/lib';
use PAGITest::Stringy;
use PAGI::Utils;
use PAGI::Headers;
use PAGI::Pages;
use PAGI::Response qw(response);
use PAGI::SSE;
use PAGI::WebSocket;
use PAGITest::Connected qw(ws_scope sse_scope);

# One rule for every header value Tools sends (items 1 and 2), and one
# headers argument in three shapes at every site that takes one.

subtest 'the one header value rule' => sub {
    my $check = \&PAGI::Utils::_sendable_header_value;
    is([ $check->(PAGITest::Stringy::Overloaded->new('ok')) ], ['ok'], 'an overloading object gives its string');
    my ($bytes) = $check->(Encode::decode('UTF-8', 'plain'));
    is($bytes, 'plain', 'flagged ASCII is bytes');
    ok(!utf8::is_utf8($bytes), 'given back as plain bytes');
    is([ $check->(PAGITest::Stringy::Plain->new) ], [undef, 'not a string'], 'a plain object is not a string');
    is([ $check->([1]) ],                           [undef, 'not a string'], 'nor is a reference');
    is([ $check->(undef) ],                         [undef, 'not a string'], 'nor undef');
    is([ $check->("smile \x{263a}") ],              [undef, 'wide'],         'a wide character is not bytes');
};

my $file = quotemeta __FILE__;
my @pairs = (['X-A', '1'], ['Set-Cookie', 'a=1'], ['Set-Cookie', 'b=2']);
sub shapes {
    return (
        flat    => [ map { @$_ } @pairs ],
        pairs   => [ map { [@$_] } @pairs ],
        headers => PAGI::Headers->new([ map { [@$_] } @pairs ]),
    );
}
# The headers a site sent that these tests set, in order.
sub ours {
    my ($sent) = @_;
    return [ map { [ $_->[0] =~ /\Ax-a\z/i ? 'X-A' : 'Set-Cookie', $_->[1] ] }
             grep { $_->[0] =~ /\A(?:x-a|set-cookie)\z/i } @{ $sent // [] } ];
}
sub start_of { (grep { $_->{type} eq 'http.response.start' } @{ $_[0] })[0] }

my %site = (
    'PAGI::Response' => sub {
        start_of(PAGITest::Stringy::events_of(response('Text', 'x', headers => $_[0])))->{headers};
    },
    'PAGI::Pages' => sub {
        my $app = PAGI::Pages->not_found(headers => $_[0]);
        my @events;
        Future->wrap($app->to_app->({ type => 'http', method => 'GET', path => '/', raw_path => '/',
            query_string => '', headers => [] }, sub { Future->done }, sub { push @events, $_[0]; Future->done }))->get;
        start_of(\@events)->{headers};
    },
    'PAGI::WebSocket accept' => sub {
        my @sent;
        PAGI::WebSocket->new(ws_scope(), sub { Future->done({ type => 'websocket.connect' }) },
            sub { push @sent, $_[0]; Future->done })->accept(headers => $_[0])->get;
        $sent[0]{headers};
    },
    'PAGI::SSE start' => sub {
        my @sent;
        PAGI::SSE->new(sse_scope(), sub {}, sub { push @sent, $_[0]; Future->done })->start(headers => $_[0])->get;
        $sent[0]{headers};
    },
);

for my $label (sort keys %site) {
    my $send = $site{$label};
    subtest "$label takes headers in three shapes" => sub {
        my %shape = shapes();
        for my $shape (sort keys %shape) {
            is(ours($send->($shape{$shape})), \@pairs, "$shape: sent in order, duplicates kept");
        }
        is(ours($send->([])), [], 'an empty list');
        is(ours($send->(PAGI::Headers->new)), [], 'an empty PAGI::Headers');

        my $given = PAGI::Headers->new([['X-A', '1']]);
        my $sent = $send->($given);
        $given->add('X-A', 'later');
        is($given->to_pairs, [['X-A', '1'], ['X-A', 'later']], 'the PAGI::Headers given is not changed');
        is(ours($sent), [['X-A', '1']], 'and a later change to it does not reach what was sent');

        my $shape_error = qr/\Q$label\E headers must be a flat \[name => value\] list, \[\[name, value\]\] pairs, or a PAGI::Headers object at $file line/;
        for my $bad (
            [ 'an odd flat list',               ['X-A'] ],
            [ 'a pair that is not two elements', [['X-A']] ],
            [ 'pairs mixed with flat',           [['X-A', 1], 'Y', 2] ],
            [ 'a reference as a name',           ['X-A', 1, {}, 2] ],
            [ 'an undefined name',               ['X-A', 1, undef, 2] ],
            [ 'a pair with a reference name',    [[[], 1]] ],
            [ 'a hash',                          { 'X-A' => 1 } ],
            [ 'another object',                  PAGITest::Stringy::Plain->new ],
            [ 'a string',                        'X-A' ],
        ) {
            my ($what, $value) = @$bad;
            like(dies { $send->($value) }, $shape_error, "$what is refused");
        }
    };
}

subtest 'accept and start send values by the one rule' => sub {
    for my $label ('PAGI::WebSocket accept', 'PAGI::SSE start') {
        my $send = $site{$label};
        is(ours($send->([ 'X-A' => PAGITest::Stringy::Overloaded->new('ok') ])), [['X-A', 'ok']],
            "$label: an overloading object is sent as its string");
        ok(!ref $send->([['X-A', PAGITest::Stringy::Overloaded->new('ok')]])->[0][1], "$label: as a plain string");
        like(dies { $send->(['X-A' => PAGITest::Stringy::Plain->new]) },
            qr/header 'X-A' value must be a string or an object that overloads stringification at $file line/,
            "$label: a plain object is refused");
        like(dies { $send->(['X-A' => "smile \x{263a}"]) },
            qr/header 'X-A' value contains a character above 0xFF: encode it first at $file line/,
            "$label: a wide character is refused");
    }
};

subtest 'header names are HTTP tokens at every site' => sub {
    my $not_token = qr/header name (?:'[^']*' )?must be an HTTP token/;
    my %direct = (
        'header()'           => sub { response('Text', 'x')->header($_[0][0], $_[0][1]); [] },
        'an added header'    => sub {
            my $response = response('Text', 'x');
            $response->headers->add(@{ $_[0] });
            start_of(PAGITest::Stringy::events_of($response))->{headers};
        },
    );
    my %every = (%direct, map { my $send = $site{$_}; ($_ => sub { $send->([ @{ $_[0] } ]) }) } keys %site);
    for my $label (sort keys %every) {
        my $send = $every{$label};
        is(ours($send->(['X-A', '1'])), $label =~ /\(\)/ ? [] : [['X-A', '1']], "$label: a token is accepted");
        ok(lives { $send->(["!#\$%&'*+-.^_`|~09az", 'v']) }, "$label: every token character is accepted");
        for my $bad (
            [ 'a space',            'Bad Name' ],
            [ 'a colon',            'X:Y' ],
            [ 'a Latin-1 character', "X-Caf\xE9" ],
            [ 'a wide character',   "X-\x{263a}" ],
        ) {
            my ($what, $name) = @$bad;
            # Added straight to the container, a name is refused when the
            # response is sent, at the line that sends it.
            my $where = $label eq 'an added header' ? qr/ at / : qr/ at $file line/;
            like(dies { $send->([$name, 'v']) }, qr/$not_token$where/, "$label: a name with $what is refused");
        }
    }
    like(dies { response('Text', 'x')->header("X-\x{263a}", 'v') }, qr/'X-\\x\{263A\}'/,
        'the refused name is shown with unprintable characters escaped');
};

subtest 'Empty and Redirect refuse their own headers in every shape' => sub {
    for my $case (
        [ Empty    => [],     'Content-Type', qr/Empty response does not permit Content-Type/ ],
        [ Redirect => ['/x'], 'Location',     qr/Redirect Location is response-owned/ ],
    ) {
        my ($name, $args, $owned, $refused) = @$case;
        for my $given (
            [ flat    => [ $owned => 'x' ] ],
            [ pairs   => [ [ $owned, 'x' ] ] ],
            [ headers => PAGI::Headers->new([ [ $owned, 'x' ] ]) ],
        ) {
            like(dies { response($name, @$args, headers => $given->[1]) }, $refused, "$name: $given->[0]");
        }
    }
};

done_testing;
