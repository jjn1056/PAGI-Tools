package PAGITest::LowercaseHeaders;

use strict;
use warnings;

use PAGI::Test::Client;

# Tools' own tests send response header names in lowercase, as PAGI Www.pod
# says an application should: a test file that uses this module builds every
# PAGI::Test::Client with lowercase_headers on, unless the test passes
# lowercase_headers => 0. The real constructor runs; only the default
# changes.

my $new = \&PAGI::Test::Client::new;
{
    no warnings 'redefine';
    *PAGI::Test::Client::new = sub {
        my ($class, %args) = @_;
        return $new->($class, lowercase_headers => 1, %args);
    };
}

1;
