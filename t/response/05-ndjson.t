use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use JSON::MaybeXS qw(decode_json);
use PAGI::Response qw(response);
use PAGI::Test::Client;

# What a client receives when the response is served.
sub serve {
    my ($response) = @_;
    return PAGI::Test::Client->new(app => $response->to_app)->get('/');
}

my $ndjson = response('NDJSON', sub { });

subtest 'format_item turns one value into one line of JSON' => sub {
    is($ndjson->format_item({ id => 1 }), qq|{"id":1}\n|, 'an object');
    is($ndjson->format_item([1, 'two']), qq|[1,"two"]\n|, 'an array');
    is($ndjson->format_item(undef), "null\n", 'undef is null, not end of stream');
    is($ndjson->format_item("line\nbreak"), qq|"line\\nbreak"\n|,
        'a newline inside a string is escaped, so a record is always one line');
    is($ndjson->format_item("a\r\nb"), qq|"a\\r\\nb"\n|, 'so is a carriage return');
    is($ndjson->format_item(4.5), "4.5\n", 'a number');
    is($ndjson->format_item(\1), "true\n", 'a boolean');
    is($ndjson->format_item({ active => \0 }), qq|{"active":false}\n|,
        'a boolean inside an object');
};

subtest 'format_item returns UTF-8 bytes' => sub {
    my $line = $ndjson->format_item("caf\x{e9}");
    ok(!utf8::is_utf8($line), 'bytes, not characters');
    is(decode_json($line), "caf\x{e9}", 'decodes back to the same text');
};

subtest 'format_item refuses a value JSON cannot represent' => sub {
    like(dies { $ndjson->format_item(bless {}, 'Unencodable') },
        qr/NDJSON item encoding failed/);
};

subtest 'an NDJSON response streams one line per write_item' => sub {
    my $res = serve(response('NDJSON', async sub {
        my ($writer) = @_;
        await $writer->write_item({ id => 1 });
        await $writer->write_item({ id => 2 });
    }));
    is($res->status, 200);
    is($res->header('Content-Type'), 'application/x-ndjson');
    is([map { decode_json($_) } split /\n/, $res->content],
        [{ id => 1 }, { id => 2 }]);
};

subtest 'status, headers and content type are ordinary response options' => sub {
    my $res = serve(response('NDJSON', sub { },
        status       => 201,
        content_type => 'application/vnd.example+ndjson',
        headers      => ['X-Export' => 'people'],
    ));
    is($res->status, 201);
    is($res->header('Content-Type'), 'application/vnd.example+ndjson');
    is($res->header('X-Export'), 'people');
};

subtest 'a producer that writes nothing sends an empty body' => sub {
    is(serve(response('NDJSON', sub { }))->content, '');
};

subtest 'a value that cannot be encoded mid-stream fails the response' => sub {
    my $client = PAGI::Test::Client->new(
        app => response('NDJSON', async sub {
            await $_[0]->write_item({ id => 1 });
            await $_[0]->write_item(bless {}, 'Unencodable');
        })->to_app,
        raise_app_exceptions => 1,
    );
    like(dies { $client->get('/') }, qr/NDJSON item encoding failed/);
};

subtest 'a producer that is not a coderef is an error naming NDJSON' => sub {
    like(dies { response('NDJSON', 'not a producer') },
        qr/^PAGI::Response::NDJSON->new requires a producer coderef/);
};

done_testing;
