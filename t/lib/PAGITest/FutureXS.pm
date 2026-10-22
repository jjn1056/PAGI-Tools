package PAGITest::FutureXS;
use strict;
use warnings;
use Exporter 'import';
use version ();
our @EXPORT_OK = qw(known_future_xs_warning);

# Future::XS before 0.16 warns "lost a sequence Future" when a without_cancel
# Future is dropped before its original resolves, at times with "Use of
# uninitialized value in subroutine entry" (RT #181389, fixed in 0.16).
sub known_future_xs_warning {
    my ($warning) = @_;
    return 0 unless $INC{'Future/XS.pm'}
        && version->parse(Future::XS->VERSION) < version->parse('0.16');
    return $warning =~ /lost a sequence Future|uninitialized value in subroutine entry/;
}

1;
