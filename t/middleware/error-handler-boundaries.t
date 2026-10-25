use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use lib 't/lib';
use PAGITest::Invoke qw(invoke refresh);
use PAGI::Exception::HTTP;
use PAGI::Middleware::ErrorHandler;
use PAGI::Response qw(response);
use PAGI::Utils ();

# ErrorHandler is two boundaries, as Starlette's application stack is:
# - the exception boundary handles an expected error -- a registered catch
#   entry, or the built-in answer to an HTTP error -- and the error ends
#   there, whatever the status of the answer;
# - the server-error boundary answers anything else with handler (or
#   catch{status}, or the built-in 500) and always rethrows it, so the
#   server logs it.
# Asserted on the app's own Future, through PAGITest::Invoke.

package Local::Busy { sub new { bless {}, shift } }
package Local::Conflict { sub new { bless {}, shift } }

sub failing_with {
    my ($error) = @_;
    return async sub { die $error };
}

subtest 'a registered exception answered with 503 is handled, not rethrown' => sub {
    my $app = PAGI::Middleware::ErrorHandler->new(catch => {
        'Local::Busy' => sub { response('Text', 'busy', status => 503) },
    })->wrap(failing_with(Local::Busy->new));
    my $r = invoke($app);
    is [$r->{status}, $r->{body}], [503, 'busy'], 'the entry answers';
    ok $r->{future}->is_done, 'and the error ends there';
};

subtest 'an unhandled error answered 200 by handler is still rethrown' => sub {
    my $app = PAGI::Middleware::ErrorHandler->new(
        handler => sub { response('Text', 'sorry', status => 200) },
    )->wrap(failing_with("database down\n"));
    my $r = invoke($app);
    is [$r->{status}, $r->{body}], [200, 'sorry'], 'handler answers';
    ok $r->{future}->is_failed, 'and the error is rethrown';
    is(($r->{future}->failure)[0], "database down\n", 'the original error');
};

subtest 'a thrown HTTP error with no entry gets the built-in answer; handler is not called' => sub {
    my $called = 0;
    my $app = PAGI::Middleware::ErrorHandler->new(
        handler => sub { $called++; response('Text', 'handler', status => 500) },
    )->wrap(async sub { PAGI::Exception::HTTP->throw(404, 'no such note') });
    my $r = invoke($app);
    is $r->{status}, 404, 'its own status';
    like $r->{body}, qr/no such note/, 'the built-in answer, with its message';
    is $called, 0, 'handler is for unhandled errors only';
    ok $r->{future}->is_done, 'handled: not rethrown';
};

subtest 'a plain error: handler answers it, or catch for the configured status' => sub {
    my $r = invoke(PAGI::Middleware::ErrorHandler->new(
        handler => sub { response('Text', 'handler') },
    )->wrap(failing_with("boom\n")));
    is [$r->{status}, $r->{body}], [500, 'handler'], 'handler, with the error status';
    $r = invoke(PAGI::Middleware::ErrorHandler->new(
        catch => { 500 => sub { response('Text', 'caught 500') } },
    )->wrap(failing_with("boom\n")));
    is [$r->{status}, $r->{body}], [500, 'caught 500'], 'catch{500}';
    $r = invoke(PAGI::Middleware::ErrorHandler->new(
        status => 503, catch => { 503 => sub { response('Text', 'caught 503') } },
    )->wrap(failing_with("boom\n")));
    is [$r->{status}, $r->{body}], [503, 'caught 503'], 'catch{<configured status>}';
    ok $r->{future}->is_failed, 'all rethrown';
};

subtest 'an error after the response started: not answered again, reported once' => sub {
    my @reported;
    my $app = PAGI::Middleware::ErrorHandler->new(
        on_error => sub { push @reported, $_[0] },
        catch    => { 404 => sub { response('Text', 'entry') } },
    )->wrap(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'partial', more => 1 });
        PAGI::Exception::HTTP->throw(404, 'too late');
    });
    my $r = invoke($app);
    is scalar(grep { $_->{type} eq 'http.response.start' } @{ $r->{events} }), 1, 'one response start';
    is $r->{body}, 'partial', 'nothing more was sent';
    is scalar(@reported), 1, 'on_error once';
    ok $r->{future}->is_failed, 'rethrown for the server';
};

subtest 'on_error runs before the answer, in both boundaries' => sub {
    my @sequence;
    my $eh = PAGI::Middleware::ErrorHandler->new(
        on_error => sub { push @sequence, 'on_error' },
        catch    => { 'Local::Conflict' => sub { push @sequence, 'entry'; response('Text', 'c', status => 409) } },
        handler  => sub { push @sequence, 'handler'; response('Text', 'h') },
    );
    invoke($eh->wrap(failing_with(Local::Conflict->new)));
    is \@sequence, ['on_error', 'entry'], 'the exception boundary';
    @sequence = ();
    invoke($eh->wrap(failing_with("boom\n")));
    is \@sequence, ['on_error', 'handler'], 'the server-error boundary';
};

subtest "an entry's own failure goes outward, and handler answers it" => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my @reported;
    my $app = PAGI::Middleware::ErrorHandler->new(
        on_error => sub { push @reported, ref($_[0]) || $_[0] },
        catch    => { 'Local::Conflict' => sub { die "template failed\n" } },
        handler  => sub { response('Text', 'handler answered') },
    )->wrap(failing_with(Local::Conflict->new));
    my $r = invoke($app);
    is [$r->{status}, $r->{body}], [500, 'handler answered'], 'the failure is answered by handler';
    is \@reported, ['Local::Conflict', "template failed\n"], 'on_error: the conflict, then the failure';
    is(($r->{future}->failure)[0], "template failed\n", 'the failure itself goes to the server');
};

subtest "a failing handler propagates its own failure, not a fallback and the original" => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my (@inner, @outer);
    my $inner = PAGI::Middleware::ErrorHandler->new(
        on_error => sub { push @inner, $_[0] },
        handler  => sub { die "renderer broke\n" },
    );
    my $outer = PAGI::Middleware::ErrorHandler->new(
        on_error => sub { push @outer, $_[0] },
        handler  => sub { response('Text', 'outer answered') },
    );
    my $r = invoke($outer->wrap($inner->wrap(failing_with("db down\n"))));
    is [$r->{status}, $r->{body}], [500, 'outer answered'], 'the next ErrorHandler out answers the failure';
    is \@inner, ["db down\n"], 'the inner one reported the original';
    is \@outer, ["renderer broke\n"], 'the outer one, the failure';
    is(($r->{future}->failure)[0], "renderer broke\n", 'the failure goes on to the server');

    $r = invoke($inner->wrap(failing_with("db down\n")));
    is scalar(@{ $r->{events} }), 0, 'with nothing outside, nothing is sent here (the server answers)';
    is(($r->{future}->failure)[0], "renderer broke\n", 'and the server gets the failure');
    is scalar(grep { /handler failed while answering "db down": renderer broke/ } @warnings), 2,
        'each time, the displaced original is named once';
};

subtest "a displaced original is named in one line, wherever the answer fails" => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $r = invoke(PAGI::Middleware::ErrorHandler->new(
        handler => sub { die "the 500 template failed\n" },
    )->wrap(failing_with("an ordinary bug\n")));
    is \@warnings, [qq{PAGI ErrorHandler handler failed while answering "an ordinary bug": the 500 template failed\n}],
        'the server-error boundary: the handler';
    is(($r->{future}->failure)[0], "the 500 template failed\n", 'and the failure goes on untouched');

    @warnings = ();
    $r = invoke(PAGI::Middleware::ErrorHandler->new(
        catch => { 'Local::Conflict' => sub { die "the conflict page failed\n" } },
    )->wrap(failing_with(Local::Conflict->new)));
    is scalar(@warnings), 1, 'the exception boundary: one line';
    like $warnings[0], qr/\APAGI ErrorHandler catch entry failed while answering "Local::Conflict=HASH\(0x[0-9a-f]+\)": the conflict page failed$/,
        'naming the entry, the original and the failure';
};

subtest 'a handler that answers nothing: the last resort, and the original' => sub {
    my $warnings = [];
    local $SIG{__WARN__} = sub { push @$warnings, @_ };
    my $r = invoke(PAGI::Middleware::ErrorHandler->new(
        handler => PAGI::Utils::as_app_object(async sub { return }),
    )->wrap(failing_with("db down\n")));
    is $r->{status}, 500, 'the last resort';
    is(($r->{future}->failure)[0], "db down\n", 'the original is rethrown');
    like $warnings->[0], qr/finished without starting a response/, 'and it says so';
};

subtest 'two requests at once through one ErrorHandler keep their own state' => sub {
    my @reported;
    my ($gate_a, $gate_b) = (Future->new, Future->new);
    my $app = PAGI::Middleware::ErrorHandler->new(
        on_error => sub { push @reported, $_[0] },
    )->wrap(async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{path} eq '/a') { await $gate_a; die "a failed\n" }
        await $gate_b;
        await response('Text', 'b ok')->to_app->($scope, $receive, $send);
    });
    my $a = invoke($app, path => '/a');
    my $b = invoke($app, path => '/b');
    $gate_a->done;
    $gate_b->done;
    refresh($_) for $a, $b;
    is [$b->{status}, $b->{body}], [200, 'b ok'], 'b answers normally';
    is $a->{status}, 500, 'a gets its own 500';
    is \@reported, ["a failed\n"], 'only a is reported';
};

done_testing;
