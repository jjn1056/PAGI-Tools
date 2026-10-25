use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use lib 't/lib';
use PAGITest::Invoke qw(invoke);
use PAGI::Exception::HTTP;
use PAGI::Middleware::ErrorHandler;
use PAGI::Test::Client;
use PAGI::Tools qw(compose middleware mount response route router);
use PAGI::Utils qw(as_app_object);

# Compose splits its ErrorHandler as Starlette's application stack is built:
#   emergency (server-only) -> configured server-error boundary
#     -> application middleware -> configured exception boundary -> router
# so an application middleware's error is answered by handler, never catch.
# Placed on a Route, a Mount or bare, an ErrorHandler wraps both halves around
# what follows it.

package Local::Conflict { sub new { bless {}, shift } }

my $conflict_entry = sub { response('Text', 'caught', status => 409) };

sub throwing_middleware {
    return middleware(sub {
        my ($app) = @_;
        return async sub { die Local::Conflict->new };
    });
}

sub error_handler {
    my ($reported) = @_;
    return middleware('ErrorHandler',
        catch    => { 'Local::Conflict' => $conflict_entry },
        handler  => sub { response('Text', 'handler') },
        on_error => sub { push @$reported, ref($_[0]) || $_[0] },
    );
}

subtest 'in Compose, an application middleware error goes to handler, never catch' => sub {
    for my $order ('before', 'after') {
        my @reported;
        my @middleware = $order eq 'before'
            ? (throwing_middleware(), error_handler(\@reported))
            : (error_handler(\@reported), throwing_middleware());
        my $app = compose(routes => [route('/' => sub { response('Text', 'ok') })], middleware => \@middleware);
        my $r = invoke($app->to_app);
        is [$r->{status}, $r->{body}], [500, 'handler'], "listed $order the ErrorHandler: handler answers";
        is \@reported, ['Local::Conflict'], 'on_error saw it';
        is scalar(grep { $_->{type} eq 'http.response.start' } @{ $r->{events} }), 1, 'answered once';
        ok $r->{future}->is_failed, 'and rethrown for the server';
    }
};

subtest "in Compose, the ErrorHandler's place in the list does not matter" => sub {
    my $pass = middleware(sub { my ($app) = @_; $app });
    for my $at (0, 1, 2) {
        my @middleware = ($pass, $pass);
        splice @middleware, $at, 0, error_handler([]);
        my $app = compose(routes => [route('/' => sub { die Local::Conflict->new })], middleware => \@middleware);
        my $r = invoke($app->to_app);
        is [$r->{status}, $r->{body}], [409, 'caught'], "at position $at: the route's error is caught";
    }
};

subtest 'a second ErrorHandler in Compose middleware dies when the application is built' => sub {
    my $app = compose(routes => [route('/' => sub { response('Text', 'ok') })],
        middleware => [middleware('ErrorHandler'), middleware('ErrorHandler')]);
    like dies { $app->to_app }, qr/one ErrorHandler/, 'it says why';
};

{
    package Local::OwnErrorHandler;
    use parent -norequire, 'PAGI::Middleware::ErrorHandler';
    our $wrapped = 0;
    sub wrap { my ($self, $app) = @_; $wrapped++; return $self->SUPER::wrap($app) }
}

subtest 'a subclass is not split: its own wrap runs, at its place' => sub {
    local $Local::OwnErrorHandler::wrapped = 0;
    my $app = compose(routes => [route('/' => sub { die Local::Conflict->new })],
        middleware => [middleware(Local::OwnErrorHandler->new(catch => { 'Local::Conflict' => $conflict_entry }))]);
    my $r = invoke($app->to_app);
    is $Local::OwnErrorHandler::wrapped, 1, 'its wrap ran';
    is [$r->{status}, $r->{body}], [409, 'caught'], 'and it answers';
};

subtest 'with no configured ErrorHandler' => sub {
    my $app = compose(routes => [route('/' => sub { response('Text', 'ok') })],
        middleware => [middleware(sub { my ($app) = @_; async sub { PAGI::Exception::HTTP->throw(409, 'from middleware') } })]);
    my $r = invoke($app->to_app);
    is $r->{status}, 500, 'an HTTP error from application middleware is a 500 (strict Starlette)';
    ok $r->{future}->is_failed, 'and rethrown';
    $app = compose(routes => [route('/' => sub { PAGI::Exception::HTTP->throw(404, 'no such note') })]);
    $r = invoke($app->to_app);
    is $r->{status}, 404, "a route's thrown HTTP error still gets its own answer";
    ok $r->{future}->is_done, 'handled';
};

my $native_conflict = as_app_object(async sub { die Local::Conflict->new });
sub local_handler { middleware('ErrorHandler', catch => { 'Local::Conflict' => $conflict_entry }) }

subtest 'the same registered exception and catch table at every placement' => sub {
    my %apps = (
        'Compose, a native endpoint' => compose(
            routes => [route('/x' => $native_conflict)], middleware => [local_handler()])->to_app,
        'a Route, around a native endpoint' => compose(
            routes => [route('/x' => $native_conflict, middleware => [local_handler()])])->to_app,
        'a Mount, around a native app' => compose(
            routes => [mount('/x', app => $native_conflict, middleware => [local_handler()])])->to_app,
        'a Mount, around a child Router' => compose(
            routes => [mount('/x', app => router(routes => [route('/' => sub { die Local::Conflict->new })]),
                middleware => [local_handler()])])->to_app,
        'bare' => PAGI::Middleware::ErrorHandler->new(catch => { 'Local::Conflict' => $conflict_entry })
            ->wrap(async sub { die Local::Conflict->new }),
    );
    for my $placement (sort keys %apps) {
        my $path = $placement =~ /child Router/ ? '/x/' : '/x';
        my $r = invoke($apps{$placement}, path => $path);
        is [$r->{status}, $r->{body}], [409, 'caught'], "$placement: caught";
        ok $r->{future}->is_done, "$placement: handled";
    }
};

subtest 'placed locally: middleware after the ErrorHandler is covered, before it is not' => sub {
    my $after = compose(routes => [route('/x' => sub { response('Text', 'ok') },
        middleware => [local_handler(), throwing_middleware()])]);
    is invoke($after->to_app, path => '/x')->{status}, 409, 'listed after: caught';
    my $before = compose(routes => [route('/x' => sub { response('Text', 'ok') },
        middleware => [throwing_middleware(), local_handler()])]);
    my $r = invoke($before->to_app, path => '/x');
    is $r->{status}, 500, 'listed before: not caught, a 500';
};

subtest 'nested ErrorHandlers, an unhandled error: answered once; middleware between sees the original' => sub {
    my $seen;
    my $watcher = sub {
        my ($app) = @_;
        return async sub {
            my @args = @_;
            eval { await $app->(@args); 1 } and return;
            $seen = $@;
            die $seen;
        };
    };
    my $outer = PAGI::Middleware::ErrorHandler->new(handler => sub { response('Text', 'outer') });
    my $inner = PAGI::Middleware::ErrorHandler->new(handler => sub { response('Text', 'inner') });
    my $r = invoke($outer->wrap($watcher->($inner->wrap(async sub { die Local::Conflict->new }))));
    is [$r->{status}, $r->{body}], [500, 'inner'], "the inner handler's answer";
    is scalar(grep { $_->{type} eq 'http.response.start' } @{ $r->{events} }), 1, 'the outer does not answer again';
    isa_ok $seen, ['Local::Conflict'], 'the middleware between them got the original exception';
    isa_ok(($r->{future}->failure)[0], ['Local::Conflict'], 'and so does the server');
};

done_testing;
