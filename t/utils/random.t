#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use PAGI::Utils::Random qw(secure_random_bytes);

subtest 'Crypt::URandom is the random source' => sub {
    ok $INC{'Crypt/URandom.pm'}, 'loaded with the module';
    no warnings 'redefine';
    local *Crypt::URandom::urandom = sub { 'u' x $_[0] };
    is secure_random_bytes(4), 'uuuu', 'the bytes come from Crypt::URandom';
};

subtest 'returns correct length' => sub {
    for my $len (1, 8, 16, 32, 64) {
        my $bytes = secure_random_bytes($len);
        is length($bytes), $len, "secure_random_bytes($len) returns $len bytes";
    }
};

subtest 'successive calls return different values' => sub {
    my $a = secure_random_bytes(32);
    my $b = secure_random_bytes(32);
    ok $a ne $b, 'two calls produce different output';
};

subtest 'zero bytes is an empty string' => sub {
    is secure_random_bytes(0), '', 'zero length';
};

subtest 'an invalid length dies' => sub {
    for my $case ([undef, 'undef'], [-1, 'negative'], [1.5, 'fractional'], ['ten', 'not a number']) {
        my ($length, $label) = @$case;
        like dies { secure_random_bytes($length) },
            qr/secure_random_bytes length must be a non-negative integer/, $label;
    }
};

done_testing;
