use v5.24;
use warnings;
use Test2::V0;
use PAGI::Test::Client;

use PAGI::Response;

# Serves a response for one GET, as a strict server would.
sub get { PAGI::Test::Client->new(app => $_[0])->get('/') }

# The headers the response sent: all but the Date the client adds, as a server does.
sub sent_headers { [grep { $_->[0] ne 'date' } @{ $_[0]->header_pairs }] }

subtest 'bytes: the start, then the body' => sub {
    my $response = PAGI::Response->new('abc');
    my $res = get($response);
    is $res->status, 200, 'status 200';
    is $res->content, 'abc', 'the body';
    is sent_headers($res), [['content-length', 3], ['content-type', 'application/octet-stream']],
        'length and type worked out';
    is get($response)->content, 'abc', 'served again: the same (a reusable value)';
    is(PAGI::Response->new(content => 'abc')->body, 'abc', 'content by name');
};

subtest 'no content' => sub {
    my $res = get(PAGI::Response->new);
    is $res->content, '', 'an empty body';
    is sent_headers($res), [['content-length', 0]], 'length 0, no type';
    is(PAGI::Response->new(undef)->body, '', 'undef is no content');
};

subtest 'statuses without a body get no content-length' => sub {
    for my $status (204, 304) {
        my $res = get(PAGI::Response->new(status => $status));
        is $res->status, $status, "$status served";
        is sent_headers($res), [], "$status: no headers";
    }
    is(PAGI::Response->new(status => 101)->start_headers, [], '1xx');
    is get(PAGI::Response->new(status => 205))->header('content-length'), 0, '205: its body is empty';
};

subtest 'statuses without content get no default content-type' => sub {
    for my $status (204, 304) {
        is(PAGI::Response->new('abc', status => $status)->start_headers, [], "$status: no type, no length");
    }
    is(PAGI::Response->new(status => 304, content_type => 'image/png')->start_headers, [['content-type', 'image/png']],
        'a content_type you give is sent');
    is(PAGI::Response->new(status => 304, headers => [['Content-Type', 'image/png']])->start_headers, [['content-type', 'image/png']],
        'and so is a content-type header');
    is(PAGI::Response->new('abc', status => 205)->start_headers, [['content-length', 3], ['content-type', 'application/octet-stream']],
        '205 is not one of them');
};

subtest 'immutable: read, never written' => sub {
    my $res = PAGI::Response->new('abc', status => 201, headers => [['X-Id', 7]], content_type => 'text/csv');
    is $res->status, 201, 'status';
    is $res->headers, [['x-id', 7]], 'headers: yours, lowercased';
    is $res->start_headers, [['x-id', 7], ['content-length', 3], ['content-type', 'text/csv']], 'start_headers: what the start sends';
    is $res->content_type, 'text/csv', 'content_type';
    is $res->body, 'abc', 'body';
    ok !$res->trailers, 'trailers';
    for my $name (qw(status headers content_type body trailers)) {
        like(dies { $res->$name(1) }, qr/\APAGI::Response is immutable: \$response->$name can't be set; build a new response/, "$name can't be set");
    }
    is $res->status, 201, 'and nothing changed';
    is(PAGI::Response->new('abc')->content_type, 'application/octet-stream', 'content_type: the default when none was given');
};

subtest 'what you gave new is copied' => sub {
    my $given = [['x-id', 7]];
    my $built = PAGI::Response->new('abc', headers => $given);
    push @$given, ['x-leak', 1];
    $given->[0][1] = 'changed';
    is $built->headers, [['x-id', 7]], 'changing your list later changes nothing';
};

subtest 'headers: yours, lowercased, and they win' => sub {
    my $given = [['X-One', 'a'], ["X-\xC9tag", 'b']];
    my $res = get(PAGI::Response->new('abc', headers => $given));
    is sent_headers($res), [['x-one', 'a'], ["x-\xC9tag", 'b'], ['content-length', 3], ['content-type', 'application/octet-stream']],
        'names lowercased (ASCII letters only), then the length and type';
    is $given, [['X-One', 'a'], ["X-\xC9tag", 'b']], 'yours are untouched';
    is sent_headers(get(PAGI::Response->new('abc', headers => [['Content-Type', 'image/png'], ['Content-Length', 3]], content_type => 'x/y'))),
        [['content-type', 'image/png'], ['content-length', 3]], 'a content-type or content-length you give is the one sent';
    my $typed = get(PAGI::Response->new('abc', content_type => 'image/png', status => 201));
    is $typed->status, 201, 'status';
    is $typed->content_type, 'image/png', 'content_type';
};

subtest 'a middleware that edits the start in place changes only that request' => sub {
    my $response = PAGI::Response->new('abc');
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
    is sent_headers(get($response)), [['content-length', 3], ['content-type', 'application/octet-stream']],
        'the response is unchanged';
};

subtest 'bytes 128-255 pass through unchanged (CONTRIBUTING.md)' => sub {
    for my $byte ("\x85", "\xA0", "\xC3\xA0", "\xC9") {
        my $res = get(PAGI::Response->new("a${byte}b", headers => [["X-$byte", "v$byte "]]));
        is sent_headers($res), [["x-$byte", "v$byte "], ['content-length', length "a${byte}b"], ['content-type', 'application/octet-stream']],
            sprintf('%vX: the name keeps it, the value is untouched, the length counts bytes', $byte);
        is $res->content, "a${byte}b", sprintf('%vX: the content is unchanged', $byte);
    }
};

subtest 'render: content must be bytes' => sub {
    like(dies { PAGI::Response->new("caf\x{e9} \x{263A}") }, qr/\APAGI::Response content must be bytes: encode it first, or use PAGI::Response::Text/,
        'a character above 0xFF');
    like(dies { PAGI::Response->new([1]) }, qr/\APAGI::Response content must be bytes/, 'a reference');
    is get(PAGI::Response->new("caf\xE9"))->content, "caf\xE9", 'bytes 128-255 are bytes';
};

package Local::CSV { use parent -norequire, 'PAGI::Response';
    sub default_content_type { 'text/csv' }
    sub render { my ($self, $rows) = @_; join '', map { join(',', @$_) . "\r\n" } @$rows } }
package Local::Checksum { use parent -norequire, 'PAGI::Response';
    sub trailers_for { my ($self, $scope) = @_; [['x-checksum', "sha256=$scope->{method}"]] } }
package main;

subtest 'a format of your own' => sub {
    my $res = get(Local::CSV->new([[1, 2], [3, 4]]));
    is $res->content, "1,2\r\n3,4\r\n", 'render';
    is $res->content_type, 'text/csv', 'its type';
};

subtest 'trailers' => sub {
    my $res = get(Local::Checksum->new('abc', trailers => 1));
    is $res->content, 'abc', 'the body';
    is $res->header('content-length'), undef, 'no content-length';
    is $res->trailer_pairs, [['x-checksum', 'sha256=GET']], 'sent after the body, per request';
    is get(PAGI::Response->new('abc', trailers => 1))->trailer_pairs, [], 'none given: empty';
    is get(Local::Checksum->new('abc'))->trailer_pairs, [], 'not declared: none sent';
};

done_testing;
