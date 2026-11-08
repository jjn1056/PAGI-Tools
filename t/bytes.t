use v5.24;
use warnings;
use Test2::V0;

# PAGI hands applications bytes, and under use v5.24 a regex or lc can change
# bytes 128-255 (CONTRIBUTING.md). Every module that takes or returns bytes
# sends these through its public methods and checks they come out unchanged.
my @BYTES = ("\x85", "\xA0", "\xC3\xA0", "\xC9");

use PAGI::Response;
package Local::Bytes { use parent -norequire, 'PAGI::Response'; }
package main;

subtest 'PAGI::Response: header names and values' => sub {
    for my $byte (@BYTES) {
        my $hex = join ' ', map { sprintf '%02X', ord } split //, $byte;
        my $r = Local::Bytes->new(headers => [["X-$byte", "v$byte "]]);
        is($r->headers, [["x-$byte", "v$byte "]], "$hex: the name keeps it (only A-Z lowercased), the value is untouched");
        is($r->response_headers(undef), [["x-$byte", "v$byte "]], "$hex: sent unchanged");
    }
};

subtest 'PAGI::Response: content and body' => sub {
    for my $byte (@BYTES) {
        my $hex = join ' ', map { sprintf '%02X', ord } split //, $byte;
        my $r = PAGI::Response->new("a${byte}b ");
        is($r->body, "a${byte}b ", "$hex: rendered unchanged");
        is($r->content_length, length("a${byte}b "), "$hex: its length in bytes");
    }
};

done_testing;
