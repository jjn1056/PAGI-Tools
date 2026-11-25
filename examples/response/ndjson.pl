#!/usr/bin/env perl
# Newline-delimited JSON with PAGI::Response::NDJSON: the body writes items,
# and each goes out as one line of JSON, as it's written. A client reads the
# lines as they come, rather than waiting for the whole response.
#
#   pagi-server --app examples/response/ndjson.pl --port 5000
#   curl -N http://localhost:5000/people          # a record every half second
#   curl -N http://localhost:5000/sorted          # the same, keys in order
#   curl -N http://localhost:5000/broken          # a record JSON can't carry ends it

use v5.40;
use utf8;
use Future::AsyncAwait;
use Future::IO;
use PAGI::Response::NDJSON;

# People, one at a time, as a database cursor would give them.
package People {
    sub new ($class) {
        return bless { rows => [
            { id => 1, name => 'Zoë',    city => 'Zürich' },
            { id => 2, name => 'Łukasz', city => 'Kraków' },
            { id => 3, name => 'João',   city => 'São Paulo' },
        ] }, $class;
    }
    sub next ($self) { return shift @{ $self->{rows} } }
}

# A format of NDJSON's own: its keys sorted, by giving it an encoder.
package Sorted::NDJSON {
    use parent -norequire, 'PAGI::Response::NDJSON';
    use JSON::MaybeXS ();
    sub json_encoder ($self) { return JSON::MaybeXS->new(utf8 => 1, canonical => 1) }
}

sub people_from ($class) {
    return $class->new(body => async sub ($writer) {
        $writer->on_close(sub ($writer) { warn 'people ended: ', $writer->outcome, "\n" });
        my $people = People->new;
        while (defined(my $person = $people->next)) {
            await $writer->write_item($person);    # one line of JSON
            await Future::IO->sleep(0.5);
        }
    });
}

my $app = async sub ($scope, $receive, $send) {
    die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';

    my $response =
        $scope->{path} eq '/people' ? people_from('PAGI::Response::NDJSON')
      : $scope->{path} eq '/sorted' ? people_from('Sorted::NDJSON')
      : $scope->{path} eq '/broken' ? PAGI::Response::NDJSON->new(body => async sub ($writer) {
            $writer->on_close(sub ($writer) { warn 'broken ended: ', $writer->outcome, "\n" });
            await $writer->write_item({ ok => 1 });
            await $writer->write_item({ handler => sub { 1 } });    # JSON can't carry code: the stream fails
        })
      : PAGI::Response::NDJSON->new(status => 404, body => async sub ($writer) {
            await $writer->write_item({ error => 'not found' });
        });

    await $response->call($scope, $receive, $send);
};

$app;
