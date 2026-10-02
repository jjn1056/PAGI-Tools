package PAGITest::XMLResponse;

# A Response class living outside PAGI::Response::, the way a CPAN
# distribution would ship one; reached with response('+PAGITest::XMLResponse').
use strict;
use warnings;
use parent 'PAGI::Response::Text';

sub default_content_type { 'application/xml; charset=utf-8' }

1;
