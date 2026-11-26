use v5.24;
use warnings;
use utf8;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util ();
use PAGI::Test::Client;

use PAGI::Exception::HTTP;
use PAGI::Middleware::ErrorHandler;
use PAGI::Response::JSON;
use PAGI::Response::Text;

# An app that throws what it's given, before responding.
sub throws {
    my ($error) = @_;
    return async sub { die $error };
}

sub http_error { PAGI::Exception::HTTP->new(@_) }

sub get {
    my ($app) = @_;
    return PAGI::Test::Client->new(app => PAGI::Middleware::ErrorHandler->wrap($app))->get('/');
}

package Local::Gone {
    sub new { bless {}, shift }
}

package Local::Errors {
    use parent -norequire, 'PAGI::Middleware::ErrorHandler';

    sub response_for {
        my ($self, $error, $scope) = @_;
        return PAGI::Response::JSON->new(status => 410, content => { error => 'deleted' })
            if Scalar::Util::blessed($error) && $error->isa('Local::Gone');
        return $self->SUPER::response_for($error, $scope);
    }
}

package Local::BadAnswer {
    use parent -norequire, 'PAGI::Middleware::ErrorHandler';
    sub response_for { die "bad answer\n" }
}

package Local::NotAResponse {
    use parent -norequire, 'PAGI::Middleware::ErrorHandler';
    sub response_for { 'not a response' }
}

# A layer that adds a header to every response start it sends on.
package Local::AddHeader {
    use parent -norequire, 'PAGI::Middleware';
    use Future::AsyncAwait;

    async sub call {
        my ($self, $scope, $receive, $send) = @_;
        my $adding = async sub {
            my ($event) = @_;
            $event = { %$event, headers => [@{ $event->{headers} }, ['x-layer', 'yes']] }
                if $event->{type} eq 'http.response.start';
            await $send->($event);
        };
        await $self->app->($scope, $receive, $adding);
    }
}

subtest 'a thrown HTTP error is answered as plain text, and ends there' => sub {
    my $res = get(throws(http_error(status_code => 404)));
    is $res->status, 404, 'its status';
    is $res->content, 'Not Found', 'no message: the reason phrase';
    is $res->header('content-type'), 'text/plain; charset=utf-8', 'plain text';
    is $res->exception, undef, 'handled: nothing goes on to the server';

    is get(throws(http_error(status_code => 404, client_message => 'No note 9.')))->content, 'No note 9.',
        'a message';
    $res = get(throws(http_error(status_code => 401, client_message => 'Sign in first.',
        headers => [['www-authenticate', 'Bearer'], ['retry-after', '30']])));
    is [$res->header('www-authenticate'), $res->header('retry-after')], ['Bearer', '30'], 'its headers are sent';
};

subtest 'a 5xx is answered, then goes on to the server' => sub {
    my $error = http_error(status_code => 503, client_message => 'Resting.', headers => [['retry-after', '30']],
        cause => 'database: connection refused');
    my $res;
    # The response is complete when the error goes on, so the client warns,
    # as a server logs it.
    like(warning { $res = get(throws($error)) },
        qr/\Aexception after response completed: 503 Resting\. \(cause: database: connection refused\)/,
        'the error goes on to the server, which logs it with its cause');
    is [$res->status, $res->content, $res->header('retry-after')], [503, 'Resting.', '30'],
        'the answer: the message shown for a 5xx too';
    my $raising = PAGI::Test::Client->new(app => PAGI::Middleware::ErrorHandler->wrap(throws($error)),
        raise_app_exceptions => 1);
    is dies { $raising->get('/') }, exact_ref($error), 'the same error, unchanged';
};

subtest 'a subclass answers its own exceptions' => sub {
    my $res = PAGI::Test::Client->new(app => Local::Errors->wrap(throws(Local::Gone->new)))->get('/');
    is [$res->status, $res->json], [410, { error => 'deleted' }], "the subclass's answer";
    is $res->exception, undef, 'handled';
    is(PAGI::Test::Client->new(app => Local::Errors->wrap(throws(http_error(status_code => 404))))->get('/')->status,
        404, 'and the parent still answers HTTP errors');
};

package Local::Page500 {
    use parent -norequire, 'PAGI::Middleware::ErrorHandler';
    sub response_for { PAGI::Response::Text->new(status => 500, content => 'Sorry.') }
}

subtest 'a 500 page of your own still lets the error go on' => sub {
    my $res;
    like(warning { $res = PAGI::Test::Client->new(app => Local::Page500->wrap(throws("boom\n")))->get('/') },
        qr/\Aexception after response completed: boom/, 'the error reaches the server');
    is [$res->status, $res->content], [500, 'Sorry.'], 'after the page is sent';
};

subtest 'anything else goes on to the server, unchanged' => sub {
    my $res = get(throws("boom\n"));
    is $res->status, 500, "the client's 500";
    is $res->exception, "boom\n", 'a string, byte for byte';

    my $gone = Local::Gone->new;
    is get(throws($gone))->exception, exact_ref($gone), 'an object no one answers, the same object';
};

subtest 'once the response started, it goes on to the server' => sub {
    my $error = http_error(status_code => 404);
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'part', more => 1 });
        die $error;
    };
    my $res = PAGI::Test::Client->new(app => PAGI::Middleware::ErrorHandler->wrap($app))->stream('/')->response;
    is [$res->status, $res->content], [200, 'part'], 'what was sent stands: no second start';
    is $res->exception, exact_ref($error), 'and the error goes on';
};

subtest 'a WebSocket before accept is refused with an HTTP response' => sub {
    my $client = PAGI::Test::Client->new(app => PAGI::Middleware::ErrorHandler->wrap(
        throws(http_error(status_code => 403, client_message => 'No.'))));
    my $ws = $client->websocket('/');
    ok $ws->refused, 'refused';
    is [$ws->response->status, $ws->response->content], [403, 'No.'], 'with the HTTP error';
};

subtest 'an SSE stream before start is refused the same way' => sub {
    my $client = PAGI::Test::Client->new(app => PAGI::Middleware::ErrorHandler->wrap(
        throws(http_error(status_code => 404))));
    my $res = $client->sse('/');
    is [$res->status, $res->content], [404, 'Not Found'], 'an HTTP 404';
};

subtest 'lifespan passes straight through' => sub {
    my $inner = async sub {
        my ($scope, $receive, $send) = @_;
        die "only lifespan here\n" unless $scope->{type} eq 'lifespan';
        while (1) {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                $scope->{state}{ready} = 'yes';
                await $send->({ type => 'lifespan.startup.complete' });
            }
            elsif ($event->{type} eq 'lifespan.shutdown') {
                await $send->({ type => 'lifespan.shutdown.complete' });
                return;
            }
        }
    };
    my $client = PAGI::Test::Client->new(app => PAGI::Middleware::ErrorHandler->wrap($inner), lifespan => 1);
    $client->start;
    is $client->state->{ready}, 'yes', "the inner app's startup ran, and its state is there";
    $client->stop;

    my $declining = PAGI::Test::Client->new(app => PAGI::Middleware::ErrorHandler->wrap(throws("no lifespan here\n")),
        lifespan => 1);
    like dies { $declining->start }, qr/no lifespan here/, "a lifespan app's own error goes on as it is";
};

subtest 'an answer that dies: one error naming both' => sub {
    my $res = PAGI::Test::Client->new(app => Local::BadAnswer->wrap(throws(http_error(status_code => 404))))->get('/');
    is $res->status, 500, "the client's 500";
    is $res->exception, "the error handler's answer failed: bad answer (while answering: 404 Not Found)\n",
        'the failure, then the error it was answering';

    $res = PAGI::Test::Client->new(app => Local::NotAResponse->wrap(throws(http_error(status_code => 404))))->get('/');
    like $res->exception, qr/\Athe error handler's answer failed: .+ \(while answering: 404 Not Found\)\n\z/s,
        'an answer that is not a response fails the same way';
};

subtest 'an app that dies before returning a Future' => sub {
    my $app = sub { die http_error(status_code => 404) };
    is get($app)->status, 404, 'answered as an async one is';
};

subtest 'a message outside ASCII is sent as UTF-8' => sub {
    is get(throws(http_error(status_code => 404, client_message => "Gr\x{fc}\x{df}e")))->content,
        "Gr\xc3\xbc\xc3\x9fe", 'the UTF-8 bytes';
};

subtest 'only the layers outside it add to its answer' => sub {
    my $app = throws(http_error(status_code => 404));
    my $outside = PAGI::Test::Client->new(app => Local::AddHeader->wrap(PAGI::Middleware::ErrorHandler->wrap($app)));
    is $outside->get('/')->header('x-layer'), 'yes', 'a layer outside it: its header is on the 404';
    my $inside = PAGI::Test::Client->new(app => PAGI::Middleware::ErrorHandler->wrap(Local::AddHeader->wrap($app)));
    is $inside->get('/')->header('x-layer'), undef, 'a layer inside it: not';
};

done_testing;
