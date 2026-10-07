use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(weaken);

use PAGI::FutureOwner;

# PAGI::FutureOwner keeps each adopted Future until it settles, and settled
# tells whoever owns the owner when everything adopted has settled.

subtest 'settled is done at once when nothing is adopted' => sub {
    ok(PAGI::FutureOwner->new->settled->is_done, 'done');
};

subtest 'adopt returns the Future it was given' => sub {
    my $owner = PAGI::FutureOwner->new;
    my $f = Future->new;
    is($owner->adopt($f), exact_ref($f), 'same Future');
    $f->done;
};

subtest 'settled waits for every adopted Future' => sub {
    my $owner = PAGI::FutureOwner->new;
    my ($one, $two) = (Future->new, Future->new);
    $owner->adopt($_) for $one, $two;
    my $settled = $owner->settled;
    $one->done;
    ok(!$settled->is_ready, 'not while one is pending');
    $two->done;
    ok($settled->is_done, 'done once both have settled');
};

subtest 'work adopted while settling is waited for too' => sub {
    my $owner = PAGI::FutureOwner->new;
    my $later = Future->new;
    my $trigger = Future->new;
    # Cleanup that starts more work (a send, say) before it completes itself.
    my $first = $trigger->then(sub { $owner->adopt($later); Future->done });
    $owner->adopt($first);
    my $settled = $owner->settled;
    $trigger->done;
    ok(!$settled->is_ready, 'still waiting for the work adopted meanwhile');
    $later->done;
    ok($settled->is_done, 'then done');
};

subtest 'the first failure fails settled, after everything has settled' => sub {
    my $owner = PAGI::FutureOwner->new;
    my ($bad, $worse, $slow) = (Future->new, Future->new, Future->new);
    $owner->adopt($_) for $bad, $worse, $slow;
    my $settled = $owner->settled;
    $bad->fail("first\n");
    $worse->fail("second\n");
    ok(!$settled->is_ready, 'not before the slow one settles');
    $slow->done;
    ok($settled->is_failed, 'failed');
    is(scalar $settled->failure, "first\n", 'with the first failure');
};

subtest 'a cancelled Future counts as settled, not failed' => sub {
    my $owner = PAGI::FutureOwner->new;
    my $f = Future->new;
    $owner->adopt($f);
    my $settled = $owner->settled;
    $f->cancel;
    ok($settled->is_done, 'done');
};

subtest 'on_failure receives each failure and settled stays successful' => sub {
    my @seen;
    my $owner = PAGI::FutureOwner->new(on_failure => sub { push @seen, $_[0] });
    my ($first, $second) = (Future->new, Future->new);
    $owner->adopt($_) for $first, $second;
    $first->fail("one\n");
    is(\@seen, ["one\n"], 'reported when it happens');
    $second->fail("two\n");
    is(\@seen, ["one\n", "two\n"], 'each failure');
    ok($owner->settled->is_done, 'settled is not failed');
};

subtest 'an adopted Future stays alive while pending, with no other reference' => sub {
    my $weak;
    {
        my $owner = PAGI::FutureOwner->new;
        my $f = Future->new;
        $owner->adopt($f);
        $weak = $f;
        weaken($weak);
    }
    ok(defined $weak, 'the owner and its pending Future keep each other alive');
    $weak->done;
    ok(!defined $weak, 'and let go once it settles');
};

subtest 'arguments are checked' => sub {
    like(dies { PAGI::FutureOwner->new(on_failure => 'x') }, qr/on_failure must be a coderef/, 'on_failure');
    like(dies { PAGI::FutureOwner->new->adopt('x') }, qr/adopt requires a Future/, 'adopt');
};

done_testing;
