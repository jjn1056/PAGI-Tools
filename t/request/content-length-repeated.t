use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request;

# A value used as a value reads headers->get_single: a field sent twice
# is absent, never "3, 3".

sub request_with {
    my (@headers) = @_;
    my @chunks = ({ type => 'http.request', body => 'abc', more => 0 });
    my $receive = sub { Future->done(shift @chunks) };
    return PAGI::Request->new(
        { type => 'http', method => 'POST', path => '/', headers => \@headers },
        $receive,
    );
}

subtest 'one Content-Length field is its value' => sub {
    my $request = request_with(['content-length', '3']);
    is $request->content_length, '3', 'content_length';
};

subtest 'a repeated Content-Length reads as absent' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $request = request_with(['content-length', '3'], ['content-length', '3']);

    is $request->content_length, undef, 'content_length is undef';
    my $stream = $request->body_stream;
    is $stream->next_chunk->get, 'abc', 'the stream reads without a limit from the header';
    is \@warnings, [], 'no "isn\'t numeric" warning';
};

done_testing;
