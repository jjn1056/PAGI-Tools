use strict;
use warnings;
use Test2::V0;
use PAGI::Middleware::Debug;
use Future::AsyncAwait;

# Test that scope values are HTML-escaped in the debug panel

my $debug = PAGI::Middleware::Debug->new(
    enabled     => 1,
    show_scope  => 1,
    show_headers => 0,
    show_timing  => 0,
);

# Build a scope with XSS payloads in every scope value
my $xss = '<script>alert("xss")</script>';
my $scope = {
    type         => 'http',
    method       => $xss,
    path         => $xss,
    query_string => $xss,
    scheme       => $xss,
    headers      => [],
};

# Capture the response body from the debug panel
my $captured_body;

my $inner_app = async sub {
    my ($scope, $receive, $send) = @_;
    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/html']],
    });
    await $send->({
        type => 'http.response.body',
        body => '<html><body>Hello</body></html>',
        more => 0,
    });
};

my $wrapped = $debug->wrap($inner_app);

my $send = async sub {
    my ($event) = @_;
    if ($event->{type} eq 'http.response.body') {
        $captured_body = $event->{body};
    }
};

my $receive = async sub { return { type => 'http.disconnect' } };

# Run the middleware
$wrapped->($scope, $receive, $send)->get;

# The raw XSS string must NOT appear in the output
unlike($captured_body, qr/<script>alert/, 'no raw script tags in debug panel output');

# The escaped version MUST appear
like($captured_body, qr/&lt;script&gt;alert/, 'XSS payload is HTML-escaped in debug panel');

# Verify each field individually
like($captured_body, qr{<th>Method</th><td>&lt;script&gt;}, 'method field is escaped');
like($captured_body, qr{<th>Path</th><td>&lt;script&gt;}, 'path field is escaped');
like($captured_body, qr{<th>Query</th><td>&lt;script&gt;}, 'query field is escaped');
like($captured_body, qr{<th>Scheme</th><td>&lt;script&gt;}, 'scheme field is escaped');

subtest 'an aborted HTML response still reaches the wire' => sub {
    {
        package AbortedConn7;
        sub new               { return bless {}, shift }
        sub is_connected      { return 0 }
        sub disconnect_reason { return 'client_closed' }
        sub on_disconnect     { return }
    }

    my @sent;
    my $send = sub { push @sent, $_[0]; return Future->done };
    my $scope = { type => 'http', method => 'GET', path => '/x', headers => [],
                  'pagi.connection' => AbortedConn7->new };

    my $app = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start', status => 200,
                headers => [['content-type', 'text/html']] });
            await $inner_send->({ type => 'http.response.body',
                body => '<html><body>partial', more => 1 });
            return;
        })->();
    };

    my $wrapped = PAGI::Middleware::Debug->new(enabled => 1)->wrap($app);
    Future->wrap($wrapped->($scope, sub { Future->done }, $send))->get;

    is(scalar(grep { $_->{type} eq 'http.response.start' } @sent), 1,
        'the start event is forwarded even though the response never completed');
    ok(scalar(grep { $_->{type} eq 'http.response.body' } @sent) >= 1,
        'the buffered body reaches the wire');
    is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @sent), 0,
        'no terminal body event is fabricated');
};

subtest 'an app that stops early with its client still connected is not swallowed' => sub {
    # The paired live-connection case. Debug's flush deliberately does NOT
    # consult disconnect state, because it synthesizes nothing -- it relays
    # what the application produced, always tagged more => 1. Gating it on
    # disconnect state would swallow this case entirely: an application bug,
    # with a client still waiting, and no response reaching the wire.
    #
    # Without this subtest the property is unpinned: both sibling cases use a
    # disconnected connection, so a disconnect-gated flush passes them.
    {
        package LiveConn7;
        sub new               { return bless {}, shift }
        sub is_connected      { return 1 }
        sub disconnect_reason { return undef }
        sub on_disconnect     { return }
    }

    my @sent;
    my $send = sub { push @sent, $_[0]; return Future->done };
    my $scope = { type => 'http', method => 'GET', path => '/x', headers => [],
                  'pagi.connection' => LiveConn7->new };

    my $app = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start', status => 200,
                headers => [['content-type', 'text/html']] });
            await $inner_send->({ type => 'http.response.body',
                body => '<html><body>partial', more => 1 });
            return;   # app bug: returns without finishing, client still there
        })->();
    };

    my $wrapped = PAGI::Middleware::Debug->new(enabled => 1)->wrap($app);
    Future->wrap($wrapped->($scope, sub { Future->done }, $send))->get;

    is(scalar(grep { $_->{type} eq 'http.response.start' } @sent), 1,
        'the start event reaches the wire despite the client being connected');
    ok(scalar(grep { $_->{type} eq 'http.response.body' } @sent) >= 1,
        'the buffered body reaches the wire');
    is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @sent), 0,
        'and still no terminal body event is fabricated');
};

subtest 'an aborted non-HTML response still forwards normally (control)' => sub {
    {
        package AbortedConn7Plain;
        sub new               { return bless {}, shift }
        sub is_connected      { return 0 }
        sub disconnect_reason { return 'client_closed' }
        sub on_disconnect     { return }
    }

    my @sent;
    my $send = sub { push @sent, $_[0]; return Future->done };
    my $scope = { type => 'http', method => 'GET', path => '/x', headers => [],
                  'pagi.connection' => AbortedConn7Plain->new };

    my $app = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start', status => 200,
                headers => [['content-type', 'text/plain']] });
            await $inner_send->({ type => 'http.response.body',
                body => 'partial', more => 1 });
            return;
        })->();
    };

    my $wrapped = PAGI::Middleware::Debug->new(enabled => 1)->wrap($app);
    Future->wrap($wrapped->($scope, sub { Future->done }, $send))->get;

    is(scalar(grep { $_->{type} eq 'http.response.start' } @sent), 1,
        'the start event forwards normally for a non-HTML response');
    is(scalar(grep { $_->{type} eq 'http.response.body' } @sent), 1,
        'the body chunk forwards normally for a non-HTML response');
    is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @sent), 0,
        'no terminal body event is fabricated for the non-HTML control either');
};

done_testing;
