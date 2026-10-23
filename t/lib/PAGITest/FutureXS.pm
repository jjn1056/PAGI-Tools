package PAGITest::FutureXS;
use strict;
use warnings;
use Exporter 'import';
use version ();
our @EXPORT_OK = qw(old_future_xs);

# True when Future::XS is loaded and older than 0.16, which warns "lost a
# sequence Future" when a without_cancel Future is dropped before its original
# resolves (RT #181389). Tests that would meet it skip; PAGI::Server's opt-in
# refuses it.
sub old_future_xs {
    return $INC{'Future/XS.pm'}
        && version->parse(Future::XS->VERSION) < version->parse('0.16') ? 1 : 0;
}

1;
