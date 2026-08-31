use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use PAGI::Middleware::ETag;
use PAGI::Middleware::GZip;
use PAGI::Compose::ResponseGuard;

{
    package AbortedConn10;
    sub new               { return bless {}, shift }
    sub is_connected      { return 0 }
    sub disconnect_reason { return 'client_closed' }
    sub on_disconnect     { return }
}

# Accept-Encoding is REQUIRED: GZip passes through untouched without it
# (GZip.pm:67-70), so a fixture with empty headers would exercise nothing.
sub aborted_scope {
    return { type    => 'http', method => 'GET', path => '/x',
             scheme  => 'http', http_version => '1.1',
             headers => [['accept-encoding', 'gzip']],
             'pagi.connection' => AbortedConn10->new };
}

# Start only, NO body event. A `more => 1` chunk trips the streaming
# passthrough -- the flip at ETag.pm:113 / GZip.pm:139, and the early return
# at ETag.pm:141 / GZip.pm:162 -- which skips the synthesis block entirely, so
# that shape would make this test pass whether or not the fixes are present.
sub aborted_app {
    return sub {
        my ($scope, $receive, $send) = @_;
        return (async sub {
            await $send->({ type => 'http.response.start', status => 200,
                headers => [['content-type', 'text/plain']] });
            return;
        })->();
    };
}

# An inner middleware must not manufacture a terminal event that would make
# an outer observer believe the response completed.
for my $case (
    ['ETag', sub { PAGI::Middleware::ETag->new->wrap($_[0]) }],
    ['GZip', sub { PAGI::Middleware::GZip->new->wrap($_[0]) }],
) {
    my ($label, $wrap) = @$case;

    subtest "$label forwards the head and fabricates no terminal event" => sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; return Future->done };

        my $inner   = $wrap->(aborted_app());
        my $guarded = PAGI::Compose::ResponseGuard->wrap($inner);

        # ResponseGuard is present to prove the stack composes, but note it is
        # inert for this fixture: ResponseGuard.pm:77 returns on
        # request_ended_abnormally before it inspects started/terminal state.
        # The assertions below therefore measure the inner middleware, not the
        # guard -- this `lives` check is a smoke test, not a discriminator.
        ok(lives {
            Future->wrap($guarded->(aborted_scope(), sub { Future->done }, $send))->get;
        }, "$label: the stack completes without raising") or note($@);

        is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @sent), 0,
            "$label: no terminal event is emitted, so completeness is not laundered");

        # The cure must not be worse than the disease: suppressing the
        # fabricated terminal must not also suppress what the application
        # really did send. That regression is not hypothetical -- it is
        # exactly the bug Task 7 fixed in Debug.
        is(scalar(grep { $_->{type} eq 'http.response.start' } @sent), 1,
            "$label: the application's own response start still reaches the wire");
    };
}

# Order independence: the same outcome whichever way the two are nested.
subtest 'detection does not depend on middleware order' => sub {
    my @orders = (
        ['ETag outside GZip', sub {
            PAGI::Middleware::ETag->new->wrap(
                PAGI::Middleware::GZip->new->wrap($_[0]))
        }],
        ['GZip outside ETag', sub {
            PAGI::Middleware::GZip->new->wrap(
                PAGI::Middleware::ETag->new->wrap($_[0]))
        }],
    );

    for my $order (@orders) {
        my ($label, $wrap) = @$order;
        my @sent;
        my $send = sub { push @sent, $_[0]; return Future->done };
        my $app  = PAGI::Compose::ResponseGuard->wrap($wrap->(aborted_app()));

        ok(lives {
            Future->wrap($app->(aborted_scope(), sub { Future->done }, $send))->get;
        }, "$label: no application error") or note($@);
        is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @sent), 0,
            "$label: no fabricated terminal event");
        is(scalar(grep { $_->{type} eq 'http.response.start' } @sent), 1,
            "$label: the response start still reaches the wire exactly once");
    }
};

done_testing;
