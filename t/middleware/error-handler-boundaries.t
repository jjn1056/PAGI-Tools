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
