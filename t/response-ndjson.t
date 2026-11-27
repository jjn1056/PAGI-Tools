use v5.24;
use warnings;
use utf8;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Test::Client;
use Test::Lib;
use PAGITest::LowercaseHeaders;

use PAGI::Response::NDJSON;

# Serves a response for one GET, as a strict server would.
sub get { PAGI::Test::Client->new(app => $_[0])->get('/') }

# A body writing each of @items, then returning.
sub writes {
    my @items = @_;
    return async sub {
        my ($writer) = @_;
        for my $item (@items) { await $writer->write_item($item) }
    };
}

{
    package Local::Point;
    sub new     { my ($class, %xy) = @_; bless {%xy}, $class }
    sub TO_JSON { my ($self) = @_; return [ $self->{x}, $self->{y} ] }
}

{
    package Local::Sorted;
    use parent -norequire, 'PAGI::Response::NDJSON';
    sub json_encoder { return JSON::MaybeXS->new(utf8 => 1, canonical => 1) }
}

subtest 'one JSON value a line' => sub {
    my $res = get(PAGI::Response::NDJSON->new(body => writes({ a => 1 }, "line\nbreak", undef)));
    is $res->status, 200, 'status 200';
    is $res->header('content-type'), 'application/x-ndjson', 'the NDJSON type';
    is [split /\n/, $res->content, -1], ['{"a":1}', '"line\nbreak"', 'null', ''],
        'three lines: a newline in a string stays escaped, undef is null';
};

subtest 'characters, sent as UTF-8' => sub {
    my $res = get(PAGI::Response::NDJSON->new(body => writes({ city => 'Zürich' })));
    is $res->content, qq({"city":"Z\xc3\xbcrich"}\n), 'the UTF-8 bytes';
};

subtest 'an item that is not plain data ends the stream failed' => sub {
    my $outcome;
    # stream, not get: get answers any failure before the end with its 500.
    my $res = PAGI::Test::Client->new(app => PAGI::Response::NDJSON->new(body => async sub {
        my ($writer) = @_;
        $writer->on_close(sub { $outcome = $_[0]->outcome });
        await $writer->write_item({ ok => 1 });
        await $writer->write_item(Local::Point->new(x => 1, y => 2));
    }))->stream('/')->response;
    is $outcome, 'failed', 'an object, even with TO_JSON: outcome failed, not converted';
    is $res->content, qq({"ok":1}\n), 'the items before it were sent';
    like $res->exception, qr/\Aencountered object '/, "and the encoder's own error";

    undef $outcome;
    $res = get(PAGI::Response::NDJSON->new(body => async sub {
        my ($writer) = @_;
        $writer->on_close(sub { $outcome = $_[0]->outcome });
        await $writer->write_item(sub { 'a code reference' });
    }));
    is $outcome, 'failed', 'a code reference: outcome failed';
    ok defined $res->exception, 'and the error reaches the caller';
};

{
    package Local::FriendlyNDJSON;
    use parent -norequire, 'PAGI::Response::NDJSON';
    sub encode_json {
        my ($self, $data) = @_;
        my $json = eval { $self->SUPER::encode_json($data) };
        return $json if defined $json;
        die "Send plain data ($@)";
    }
}

subtest 'encode_json: the hook each item is encoded through' => sub {
    my $res = PAGI::Test::Client->new(app => Local::FriendlyNDJSON->new(body => writes({ ok => 1 }, Local::Point->new)))
        ->stream('/')->response;
    is $res->content, qq({"ok":1}\n), 'items encode as before';
    like $res->exception, qr/\ASend plain data \(encountered object '/, "and a subclass says its own thing on failure";
};

subtest 'json_encoder: a subclass picks its settings' => sub {
    my $res = get(Local::Sorted->new(body => writes({ b => 2, a => 1 })));
    is $res->content, qq({"a":1,"b":2}\n), 'canonical key order from the override';
};

done_testing;
