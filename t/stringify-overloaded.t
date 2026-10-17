use strict;
use warnings;
use Test2::V0;

use lib 't/lib';
use PAGITest::Stringy;
use PAGI::Response qw(response);

# Every site that takes a string accepts an object whose class overloads ""
# and refuses every other value that is not a string. PAGITest::Stringy holds
# the cases; each site supplies how to reach it and its own refusal message.

PAGITest::Stringy::check_site(
    name    => 'Text body',
    run     => sub { PAGITest::Stringy::body_of(response('Text', $_[0])) },
    refused => qr/Text response body must be a defined Unicode scalar/,
);

PAGITest::Stringy::check_site(
    name    => 'HTML body',
    run     => sub { PAGITest::Stringy::body_of(response('HTML', $_[0])) },
    refused => qr/HTML response body must be a defined Unicode scalar/,
);

PAGITest::Stringy::check_site(
    name    => 'byte body',
    run     => sub { PAGITest::Stringy::body_of(PAGI::Response->new($_[0])) },
    refused => qr/response body must be a defined unblessed scalar of encoded bytes/,
);

done_testing;
