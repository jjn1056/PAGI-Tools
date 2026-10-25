use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use lib 'lib';
use PAGI::Middleware::ErrorHandler;
use PAGI::ErrorContext qw(error_context);
use PAGI::Exception::RequestBody;
use PAGI::Exception::HTTP;
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

# Claims a status and has a to_app that must never be used.
{
    package Local::FactWithApp;
    sub new { bless {}, $_[0] }
    sub status_code { 404 }
    sub to_app { die "a fact's to_app was called\n" }
}

# A redirect page whose rendering fails.
{
    package Local::BrokenRedirect;
    sub new { bless {}, $_[0] }
    sub status { 302 }
    sub to_app { sub { die "redirect broke\n" } }
}

# A page whose status method dies.
{
    package Local::BrokenPage;
    sub new { bless {}, $_[0] }
    sub status { die "status broke\n" }
    sub to_app { die "a broken page's to_app was called\n" }
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
    ($status, undef, $body, $failure) = run(error => PAGI::Exception::RequestBody->new(
        message => 'The request body is not valid JSON.'));
    is [$status, $body, $failure], [400, 'The request body is not valid JSON.', undef],
        'a RequestBody exception shows its client message and is handled';
};

subtest 'a catch entry gets the error; a bare Response takes its status' => sub {
    my ($status, $h, $body, $failure) = run(
        error => PAGI::Exception::RequestBody->new(message => 'bad'),
        options => { catch => { 'PAGI::Exception::RequestBody' => sub { my ($request, $error) = @_;
            response('JSON', { error => $error->message });
        } } },
    );
    is [$status, $body, $failure], [400, '{"error":"bad"}', undef], 'handled';
    ($status, $h, $body, $failure) = run(error => "db\n",
        options => { handler => sub { my ($request) = @_;
            response('JSON', { error => error_context($request)->message });
        } },
    );
    is [$status, $body, $failure], [500, '{"error":"Internal Server Error"}', "db\n"],
        'a handler reads an unhandled error with error_context, and it is re-raised';
};

subtest "an entry's explicit status and headers win" => sub {
    my ($status, $h) = run(error => Local::Status->new(404), options => { catch => { 404 => async sub {
        response('Text', 'gone', status => 410, headers => ['X-Mine' => 1]);
    } } });
    is [$status, $h->{'x-mine'}], [410, 1];
};

subtest 'a Response shared across errors takes each error\'s status' => sub {
    my $page = response('Text', 'Something went wrong');
    my %options = (handler => sub { $page }, catch => { 'PAGI::Exception::RequestBody' => sub { $page } });
    my ($status, undef, undef, $failure) = run(
        error => PAGI::Exception::RequestBody->new(message => 'bad'), options => \%options);
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

subtest 'an entry may return any application, Pages by choice' => sub {
    my ($status, $h) = run(error => Local::Status->new(404), options => { catch => { 404 => sub { my ($request, $error) = @_;
        PAGI::Pages->status($error->status);
    } } }, scope => { type => 'http', method => 'GET', path => '/', headers => [['Accept', 'text/html']] });
    is [$status, $h->{'content-type'}], [404, 'text/html; charset=utf-8'];
};

subtest 'an app object handler reads the error from its scope' => sub {
    my ($status, undef, $body) = run(error => "db\n", options => { handler => as_app_object(async sub {
        my ($scope, $receive, $send) = @_;
        my $status = error_context($scope)->status;
        await invoke_app(response('Text', "native $status", status => $status),
            $scope, $receive, $send);
    }) });
    is [$status, $body], [500, 'native 500'];
};

subtest 're-raise follows whether the error was handled, not the status sent' => sub {
    my ($status, undef, undef, $failure) = run(error => Local::Status->new(400),
        options => { catch => { 400 => sub { response('Text', 'x', status => 500) } } });
    is [$status, $failure], [500, undef], 'a handled 400 answered 500 is not re-raised';
    ($status, undef, undef, $failure) = run(error => "db\n",
        options => { handler => sub { my ($request) = @_; response('Text', 'x', status => 404) } });
    is [$status, $failure], [404, "db\n"], 'an unhandled error answered 404 is re-raised';
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
    is [$status, $failure], [200, "db\n"], 'an explicit 200 is the handler\'s answer, and the error is still re-raised';
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

subtest 'statuses needing a field the built-in answer lacks need a catch entry' => sub {
    for my $claim (401, 405, 407, 426) {
        my ($status) = run(error => Local::Status->new($claim));
        is $status, 500, "claim $claim without an entry";
        ($status) = run(error => Local::Status->new($claim),
            options => { catch => { $claim => sub { response('Text', 'x') } } });
        is $status, $claim, "claim $claim with an entry";
    }
    like dies { PAGI::Middleware::ErrorHandler->new(status => 405) }, qr/handler is required/;
    like dies { PAGI::Middleware::ErrorHandler->new(status => 302) }, qr/400 to 599/;
};

subtest "a dying handler propagates its own failure; one that answers nothing gets the last resort" => sub {
    my ($status, $h, $body, $failure, $warnings) = run(error => "db\n",
        options => { handler => sub { my ($request) = @_; die "renderer\n" } });
    is [$status, $failure], [undef, "renderer\n"],
        'nothing sent here, and the failure itself goes on (the next ErrorHandler out, or the server, answers it)';
    is $warnings, [qq{PAGI ErrorHandler handler failed while answering "db": renderer\n}],
        'one line names the displaced original';
    (undef, undef, undef, $failure, $warnings) = run(error => "db\n",
        options => { handler => sub { my ($request) = @_; 'not an app' } });
    like "$failure", qr/ErrorHandler handler must return a PAGI application/,
        'a non-application answer is a handler failure, and that failure goes on';
    ($status, undef, undef, $failure) = run(error => "db\n",
        options => { handler => as_app_object(async sub { return }) });
    is [$status, $failure], [500, "db\n"], 'an app that sends nothing';
};

subtest 'missing scope type reaches an entry as HTTP' => sub {
    my ($status, undef, $body) = run(error => Local::Status->new(404), scope => { path => '/' },
        options => { catch => { 404 => sub { my ($request) = @_; response('Text', $request->scope->{type}) } } });
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

subtest 'PAGI::Exception::HTTP is a fact with a client message' => sub {
    my $reported = 0;
    my ($status, undef, $body, $failure) = run(
        error => PAGI::Exception::HTTP->new(409, 'x'),
        options => { on_error => sub { $reported++ } },
    );
    is [$status, $body, $failure, $reported], [409, 'x', undef, 1];
};

subtest 'PAGI::Exception::HTTP accepts only 400-599' => sub {
    like dies { PAGI::Exception::HTTP->new(200) },
        qr/PAGI::Exception::HTTP status must be an integer from 400 to 599/;
};

subtest 'a 5xx PAGI::Exception::HTTP shows its reason phrase, not its client message' => sub {
    my $error = PAGI::Exception::HTTP->new(503, 'back in five minutes');
    my ($status, undef, $body, $failure) = run(error => $error);
    is [$status, $body], [503, 'Service Unavailable'];
    is $failure, undef, 'a handled HTTP error is not re-raised, whatever its status';
};

subtest 'PAGI::Exception::HTTP stringifies as status and text' => sub {
    is '' . PAGI::Exception::HTTP->new(409, 'x'), '409 x';
    is '' . PAGI::Exception::HTTP->new(404), '404 Not Found', 'the reason phrase without a message';
};

subtest 'a thrown 404 page answers as thrown under bare compose and is handled' => sub {
    my $app = compose(routes => [route('/note' => sub {
        die response('JSON', { error => 'no such note' }, status => 404);
    })]);
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $res = PAGI::Test::Client->new(app => $app)->get('/note');
    is [$res->status, $res->json, \@warnings], [404, { error => 'no such note' }, []],
        'the thrown page, not re-raised';
    my @reported;
    my ($status, undef, $body, $failure) = run(
        error => response('JSON', { error => 'no such note' }, status => 404),
        options => { on_error => sub { push @reported, $_[0] } },
    );
    is [$status, $body, $failure, scalar @reported], [404, '{"error":"no such note"}', undef, 1],
        'on_error is called';
};

subtest 'a thrown redirect is an early answer' => sub {
    my ($reported, $handled) = (0, 0);
    my ($status, $h, undef, $failure) = run(
        error => response('Redirect', '/login'),
        options => {
            on_error => sub { $reported++ },
            handler  => sub { $handled++; response('Text', 'handled') },
        },
    );
    is [$status, $h->{location}, $failure, $reported, $handled], [302, '/login', undef, 0, 0];
};

subtest 'a value with status_code and to_app is a fact; its to_app is never called' => sub {
    my ($status, undef, $body) = run(error => Local::FactWithApp->new);
    is [$status, $body], [404, 'Not Found'];
};

subtest 'a thrown 503 page answers as thrown and is handled' => sub {
    my $page = response('Text', 'down for maintenance', status => 503);
    my ($status, undef, $body, $failure) = run(error => $page);
    is [$status, $body], [503, 'down for maintenance'];
    is $failure, undef, 'a thrown page is an expected outcome: not re-raised';
};

subtest 'a thrown Response without a status is a 200 early answer' => sub {
    my $reported = 0;
    my ($status, undef, $body, $failure) = run(
        error => response('JSON', { ok => 1 }),
        options => { on_error => sub { $reported++ } },
    );
    is [$status, $body, $failure, $reported], [200, '{"ok":1}', undef, 0];
};

subtest 'a page whose status method dies is a 500, and the page is re-raised' => sub {
    my $page = Local::BrokenPage->new;
    my ($status, undef, $body, $failure, $warnings) = run(error => $page);
    is [$status, $body], [500, 'Internal Server Error'];
    is $failure, exact_ref($page);
    like $warnings->[0], qr/rejected a thrown page's status/, 'diagnosed (P-4)';
};

subtest 'a thrown redirect that fails to render goes through the error pipeline' => sub {
    my (@reported, $handled);
    my ($status, undef, $body) = run(
        error => Local::BrokenRedirect->new,
        options => {
            on_error => sub { push @reported, $_[0] },
            handler  => sub { $handled++; response('Text', 'handled') },
        },
    );
    is [$status, $body, $handled, \@reported], [500, 'handled', 1, ["redirect broke\n"]],
        'on_error and the handler see the render failure';
};

{
    package Local::AppRequest;
    use parent 'PAGI::Request';
}

subtest 'an entry receives the class the scope key builds' => sub {
    my $seen;
    my $entry = sub { my ($request, $error) = @_; $seen = ref $request; return $error->default };
    my $handler = { catch => { 'PAGI::Exception::RequestBody' => $entry } };
    my ($status, undef, undef, $failure, $warnings) = run(
        error   => PAGI::Exception::RequestBody->new(message => 'bad'),
        options => $handler,
        scope   => { type => 'http', method => 'GET', path => '/', headers => [],
            'pagi.request.factory' => sub { Local::AppRequest->new(@_) } },
    );
    is([$seen, $status, $failure, $warnings], ['Local::AppRequest', 400, undef, []],
        'a key: its class');
    run(error => PAGI::Exception::RequestBody->new(message => 'bad'), options => $handler);
    is($seen, 'PAGI::Request', 'no key: PAGI::Request');
};

done_testing;
