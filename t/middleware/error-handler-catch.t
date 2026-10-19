use strict;
use warnings;
use Test2::V0;
use Future;
use IO::Async::Loop;

use lib 'lib';
use PAGI::Middleware::ErrorHandler;
use PAGI::Exception::HTTP;
use PAGI::Response qw(response);
use Scalar::Util qw(refaddr);

# ErrorHandler's catch: answers by status and exception class, in
# Starlette's order (an HTTP error's status, then the class and its
# ancestors, then the status any other error was given), before handler.

subtest 'construction' => sub {
    my $new = sub { PAGI::Middleware::ErrorHandler->new(@_) };
    like(dies { $new->(catch => { 600 => sub {} }) },
        qr/ErrorHandler catch key '600' is neither a status from 400 to 599 nor a package name/, 'a bad status');
    like(dies { $new->(catch => { 'My Class' => sub {} }) },
        qr/ErrorHandler catch key 'My Class' is neither a status/, 'not a package name');
    like(dies { $new->(catch => { '+My::X' => sub {} }) },
        qr/ErrorHandler catch key '\+My::X' is neither a status.*write 'My::X'/, 'a leading + is refused with a hint');
    like(dies { $new->(catch => { 404 => 'x' }) },
        qr/ErrorHandler catch entry for '404' must be a code reference/, 'a non-code value');
    like(dies { $new->(catch => [404, sub {}]) },
        qr/ErrorHandler catch must be a hash reference/, 'not a hash');
    ok(lives { $new->(catch => { 404 => sub {}, 'My::X' => sub {} }) }, 'a status and a class');
    ok(lives { $new->(status => 401, catch => { 401 => sub {} }) },
        'a field-required status option is accepted with a catch entry for it');
    like(dies { $new->(status => 401, catch => { 404 => sub {} }) },
        qr/must carry WWW-Authenticate/, 'but not with an entry for another status');
};

my $loop = IO::Async::Loop->new;

{
    package MyApp::Error;    sub new { my ($class, %a) = @_; bless {%a}, $class }
    package MyApp::Conflict; our @ISA = ('MyApp::Error'); sub reason { 'taken' }
    package Left;  sub new { bless {}, shift }
    package Right; sub new { bless {}, shift }
    package Both;  our @ISA = ('Left', 'Right');
    package Claims; our @ISA = ('MyApp::Error'); sub status_code { $_[0]{status} }
}

# Runs one request through ErrorHandler; returns (status, body, failure, reported, warnings).
sub run {
    my (%args) = @_;
    my (@events, @reported, @warnings);
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $mw = PAGI::Middleware::ErrorHandler->new(
        on_error => sub { push @reported, $_[0]; Future->done },
        %{ $args{options} },
    );
    my $f = Future->wrap($mw->wrap(sub { die $args{error} })->(
        { type => 'http', method => 'GET', path => '/', headers => [] },
        sub { Future->done({ type => 'http.disconnect' }) },
        sub { push @events, $_[0]; Future->done },
    ));
    $loop->await($f->else(sub { Future->done }));
    my ($start) = grep { $_->{type} eq 'http.response.start' } @events;
    my $body = join '', map { $_->{body} // '' } grep { $_->{type} eq 'http.response.body' } @events;
    return ($start ? $start->{status} : undef, $body, $f->is_failed ? ($f->failure)[0] : undef, \@reported, \@warnings);
}

sub says { my ($text) = @_; return sub { response('Text', $text, status => 299) } }
sub bare { my ($text) = @_; return sub { response('Text', $text) } }

subtest 'which entry answers' => sub {
    my @cases = (
        [ 'an HTTP error: its status', PAGI::Exception::HTTP->new(404),
          { 404 => bare('status'), 'PAGI::Exception::HTTP' => bare('class') }, 'status' ],
        [ 'a class entry for a parent', MyApp::Conflict->new,
          { 'MyApp::Error' => bare('parent'), 500 => bare('500') }, 'parent' ],
        [ 'multiple inheritance: method resolution order', Both->new,
          { Right => bare('right'), Left => bare('left') }, 'left' ],
        [ 'a plain die: its assigned status', "db down\n", { 500 => bare('500') }, '500' ],
        [ 'a rejected status claim: its assigned status', Claims->new(status => 999),
          { 500 => bare('500') }, '500' ],
        [ 'an HTTP error with a status and a class entry: the status first', Claims->new(status => 409),
          { 409 => bare('409'), 'Claims' => bare('class') }, '409' ],
    );
    for my $case (@cases) {
        my ($label, $error, $catch, $expected) = @$case;
        my (undef, $body) = run(error => $error, options => { catch => $catch });
        is($body, $expected, $label);
    }
};

subtest 'nothing in catch: handler, else the built-in answer' => sub {
    my ($status, $body) = run(error => "db down\n", options => { catch => { 'MyApp::Error' => bare('no') } });
    is([$status, $body], [500, 'Internal Server Error'], 'the built-in answer');
    (undef, $body) = run(error => "db down\n",
        options => { catch => { 'MyApp::Error' => bare('no') }, handler => bare('handler') });
    is($body, 'handler', 'the handler');
    (undef, $body) = run(error => MyApp::Conflict->new,
        options => { catch => { 'MyApp::Error' => bare('catch') }, handler => bare('handler') });
    is($body, 'catch', 'catch before handler');
};

subtest 'an entry gets the request and the error context' => sub {
    my @got;
    my ($status) = run(error => PAGI::Exception::HTTP->new(409, 'taken'),
        options => { catch => { 409 => sub { @got = @_; response('Text', 'x') } } });
    isa_ok($got[0], ['PAGI::Request'], 'the request');
    isa_ok($got[1], ['PAGI::ErrorContext'], 'the error context');
    is($got[1]->status, 409, 'with the status');
    is($status, 409, 'a bare Response takes the error status');
    ($status) = run(error => PAGI::Exception::HTTP->new(409), options => { catch => { 409 => says('own') } });
    is($status, 299, 'a Response with its own status keeps it');
};

subtest 'a failing entry' => sub {
    for my $case ([ 'dies' => sub { die "entry broke\n" } ], [ 'returns junk' => sub { [] } ]) {
        my ($label, $entry) = @$case;
        my $error = PAGI::Exception::HTTP->new(500);
        my ($status, undef, $failure, $reported, $warnings) = run(error => $error, options => { catch => { 500 => $entry } });
        is($status, 500, "$label: the last-resort 500");
        is(refaddr($reported->[0]), refaddr($error), "$label: on_error saw the original");
        is(refaddr($failure), refaddr($error), "$label: the original is re-raised");
        like($warnings, [ qr/ErrorHandler catch entry failed/ ], "$label: diagnosed as the catch entry");
    }
};

subtest 'a failing handler is still diagnosed as the handler' => sub {
    my (undef, undef, undef, undef, $warnings) = run(error => "db down\n",
        options => { catch => { 'MyApp::Error' => bare('no') }, handler => sub { die "handler broke\n" } });
    like($warnings, [ qr/ErrorHandler handler failed: handler broke/ ], 'the handler');
};

subtest 'a field-required status answered by an entry' => sub {
    my ($status, $body, undef, undef, $warnings) = run(error => PAGI::Exception::HTTP->new(401),
        options => { catch => { 401 => sub { response('Text', 'sign in', headers => ['WWW-Authenticate' => 'Bearer']) } } });
    is([$status, $body], [401, 'sign in'], 'the entry answers');
    is($warnings, [], 'no diagnostic');
};

subtest 'thrown answers never reach catch' => sub {
    my $called = 0;
    my $catch = { 404 => sub { $called++; response('Text', 'no') },
                  'PAGI::Response' => sub { $called++; response('Text', 'no') } };
    my ($status) = run(error => response('Redirect', '/x'), options => { catch => $catch });
    is($status, 302, 'a thrown redirect is sent as it is');
    ($status) = run(error => response('Text', 'gone', status => 404), options => { catch => $catch });
    is($status, 404, 'a thrown 404 Response is sent as it is');
    is($called, 0, 'no entry was called');
};

done_testing;
