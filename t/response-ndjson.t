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

subtest 'TO_JSON encodes an object; a value JSON cannot encode ends the stream failed' => sub {
    my $res = get(PAGI::Response::NDJSON->new(body => writes(Local::Point->new(x => 1, y => 2))));
    is $res->content, "[1,2]\n", 'through TO_JSON';

    my $outcome;
    $res = get(PAGI::Response::NDJSON->new(body => async sub {
        my ($writer) = @_;
        $writer->on_close(sub { $outcome = $_[0]->outcome });
        await $writer->write_item(sub { 'a code reference' });
    }));
    is $outcome, 'failed', 'a code reference: outcome failed';
    ok defined $res->exception, 'and the error reaches the caller';
};

subtest 'json_encoder: a subclass picks its settings' => sub {
    my $res = get(Local::Sorted->new(body => writes({ b => 2, a => 1 })));
    is $res->content, qq({"a":1,"b":2}\n), 'canonical key order from the override';
};

done_testing;
