use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use lib 'lib';
use PAGI::Middleware::ErrorHandler;
use PAGI::ErrorContext qw(error_context);
use PAGI::Request::BodyError;
use PAGI::Response qw(response);
use PAGI::Utils qw(as_app_object invoke_app);
use PAGI::Pages ();
use PAGI::Compose qw(compose);
use PAGI::Routing qw(route middleware);
use PAGI::Test::Client;

my $loop = IO::Async::Loop->new;

{
    package Local::Status;
    use overload q{""} => sub { "status $_[0]{s}" }, fallback => 1;
    sub new { bless { s => $_[1] }, $_[0] }
    sub status_code { $_[0]{s} }
}

# Runs one request; returns (status, headers hashref, body, failure, warnings).
sub run { my (%args) = @_;
    my @events;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $mw = PAGI::Middleware::ErrorHandler->new(%{ $args{options} // {} });
    my $f = Future->wrap($mw->wrap($args{app} // sub { die $args{error} })->(
        $args{scope} // { type => 'http', method => 'GET', path => '/', headers => [] },
        sub { Future->done({ type => 'http.disconnect' }) },
        sub { push @events, $_[0]; Future->done },
    ));
    $loop->await($f->else(sub { Future->done }));
    my ($start) = grep { $_->{type} eq 'http.response.start' } @events;
    my %h = map { lc($_->[0]) => $_->[1] } @{ $start->{headers} // [] };
    my $body = join '', map { $_->{body} // '' } grep { $_->{type} eq 'http.response.body' } @events;
    return ($start ? $start->{status} : undef, \%h, $body,
        $f->is_failed ? ($f->failure)[0] : undef, \@warnings);
}

subtest 'the built-in answer is plain text with no-store' => sub {
    my ($status, $h, $body, $failure) = run(error => "db\n");
    is [$status, $h->{'content-type'}, $h->{'cache-control'}, $body],
        [500, 'text/plain; charset=utf-8', 'no-store', 'Internal Server Error'];
    is $failure, "db\n", 'a 5xx is re-raised';
    ($status, undef, $body, $failure) = run(error => PAGI::Request::BodyError->new(
        message => 'The request body is not valid JSON.'));
    is [$status, $body, $failure], [400, 'The request body is not valid JSON.', undef],
        'a BodyError shows its client message and is handled';
};

subtest 'a Request-handler handler reads the error; a bare Response takes its status' => sub {
    my ($status, $h, $body, $failure) = run(
        error => PAGI::Request::BodyError->new(message => 'bad'),
        options => { handler => sub { my ($request) = @_;
            response('JSON', { error => error_context($request)->message });
        } },
    );
    is [$status, $body, $failure], [400, '{"error":"bad"}', undef];
};

subtest "a handler's explicit status and headers win" => sub {
    my ($status, $h) = run(error => Local::Status->new(404), options => { handler => async sub { my ($request) = @_;
        response('Text', 'gone', status => 410, headers => ['X-Mine' => 1]);
    } });
    is [$status, $h->{'x-mine'}], [410, 1];
};

subtest 'a Response shared across errors takes each error\'s status' => sub {
    my $page = response('Text', 'Something went wrong');
    my %options = (handler => sub { my ($request) = @_; $page });
    my ($status, undef, undef, $failure) = run(
        error => PAGI::Request::BodyError->new(message => 'bad'), options => \%options);
    is [$status, $failure], [400, undef], 'the first error: 400, handled';
    ($status, undef, undef, $failure) = run(error => "database down\n", options => \%options);
    is [$status, $failure], [500, "database down\n"], 'the second error: 500, re-raised';
    ok !$page->has_status, 'the shared Response is not changed';
};

subtest 'declining: the handler returns the built-in answer' => sub {
    my ($status, undef, $body) = run(error => "db\n", options => { handler => sub { my ($request) = @_;
        my $error = error_context($request);
        return $error->default if $error->is_server_error;
        response('JSON', {});
    } });
    is [$status, $body], [500, 'Internal Server Error'];
};

subtest 'a handler may return any application, Pages by choice' => sub {
    my ($status, $h) = run(error => Local::Status->new(404), options => { handler => sub { my ($request) = @_;
        PAGI::Pages->status(error_context($request)->status);
    } }, scope => { type => 'http', method => 'GET', path => '/', headers => [['Accept', 'text/html']] });
    is [$status, $h->{'content-type'}], [404, 'text/html; charset=utf-8'];
};

subtest 'an app object handler reads the error from its scope' => sub {
    my ($status, undef, $body) = run(error => Local::Status->new(409), options => { handler => as_app_object(async sub {
        my ($scope, $receive, $send) = @_;
        await invoke_app(response('Text', 'native ' . error_context($scope)->status, status => 409),
            $scope, $receive, $send);
    }) });
    is [$status, $body], [409, 'native 409'];
};

subtest 're-raise follows the status actually sent' => sub {
    my (undef, undef, undef, $failure) = run(error => Local::Status->new(400),
        options => { handler => sub { my ($request) = @_; response('Text', 'x', status => 500) } });
    is "$failure", 'status 400', 'a 400 answered 500 is re-raised';
    (undef, undef, undef, $failure) = run(error => "db\n",
        options => { handler => sub { my ($request) = @_; response('Text', 'x', status => 404) } });
    is $failure, undef, 'a 500 answered 404 is not';
};

subtest 'handler answering 200 is not re-raised but was reported' => sub {
    my @reported;
    my ($status, undef, undef, $failure) = run(error => "db\n", options => {
        on_error => sub { push @reported, $_[0] },
        handler  => sub { my ($request) = @_; response('Text', 'oops') },
    });
    is [$status, $failure, \@reported], [500, "db\n", ["db\n"]],
        'an unset status takes the error status, 500, so it is re-raised; on_error saw it';
    ($status, undef, undef, $failure) = run(error => "db\n",
        options => { handler => sub { my ($request) = @_; response('Text', 'fine', status => 200) } });
    is [$status, $failure], [200, undef], 'an explicit 200 is the handler\'s choice';
};

subtest 'claims outside 400-599 become 500, with or without a handler' => sub {
    for my $claim (200, 302, 204, 100, 600) {
        my ($status, undef, undef, undef, $warnings) = run(error => Local::Status->new($claim));
        is $status, 500, "claim $claim, no handler";
        like $warnings->[0], qr/rejected exception status_code claim/, 'diagnosed';
        ($status) = run(error => Local::Status->new($claim),
            options => { handler => sub { my ($request) = @_; response('Text', 'x') } });
        is $status, 500, "claim $claim, with a handler";
    }
};

subtest 'statuses needing a field the built-in answer lacks need a handler' => sub {
    for my $claim (401, 405, 407, 426) {
        my ($status) = run(error => Local::Status->new($claim));
        is $status, 500, "claim $claim without a handler";
        ($status) = run(error => Local::Status->new($claim),
            options => { handler => sub { my ($request) = @_; response('Text', 'x') } });
        is $status, $claim, "claim $claim with a handler";
    }
    like dies { PAGI::Middleware::ErrorHandler->new(status => 405) }, qr/handler is required/;
    like dies { PAGI::Middleware::ErrorHandler->new(status => 302) }, qr/400 to 599/;
};

subtest 'a dying handler: last resort, warning, original re-raised' => sub {
    my ($status, $h, $body, $failure, $warnings) = run(error => "db\n",
        options => { handler => sub { my ($request) = @_; die "renderer\n" } });
    is [$status, $h->{'cache-control'}, $body, $failure], [500, 'no-store', "Internal Server Error\n", "db\n"];
    like $warnings->[0], qr/PAGI ErrorHandler handler failed: renderer/;
    (undef, undef, undef, $failure) = run(error => PAGI::Request::BodyError->new(message => 'b'),
        options => { handler => sub { my ($request) = @_; 'not an app' } });
    isa_ok($failure, ['PAGI::Request::BodyError'], 'a non-application answer is a handler failure');
    ($status, undef, undef, $failure) = run(error => "db\n",
        options => { handler => as_app_object(async sub { return }) });
    is [$status, $failure], [500, "db\n"], 'an app that sends nothing';
};

subtest 'missing scope type reaches the handler as HTTP' => sub {
    my ($status, undef, $body) = run(error => Local::Status->new(404), scope => { path => '/' },
        options => { handler => sub { my ($request) = @_; response('Text', $request->scope->{type}) } });
    is [$status, $body], [404, 'http'];
};

subtest 'an author ErrorHandler inside Compose answers once' => sub {
    my $app = compose(
        middleware => [middleware('ErrorHandler', handler => sub { my ($request) = @_;
            response('JSON', { error => error_context($request)->message });
        })],
        routes => [route('/boom' => sub { die "db\n" })],
    );
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $res = PAGI::Test::Client->new(app => $app)->get('/boom');
    is [$res->status, $res->json], [500, { error => 'Internal Server Error' }], 'one response, the author\'s';
};

done_testing;
