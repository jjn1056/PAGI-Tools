use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Response;

sub recorder {
    my @events;
    my $send = sub { my ($e) = @_; push @events, $e; Future->done };
    return ($send, \@events);
}

subtest 'detached new + respond($send) emits start+body' => sub {
    my $res = PAGI::Response->new;                 # no connection, no scope
    $res->status(201)->header('X-A' => '1')->_set_body('hi', 'text/plain');

    my ($send, $events) = recorder();
    $res->respond($send)->get;

    is $events->[0]{type}, 'http.response.start', 'start first';
    is $events->[0]{status}, 201, 'status carried';
    my %h = map { lc($_->[0]) => $_->[1] } @{$events->[0]{headers}};
    is $h{'x-a'}, '1', 'header carried';
    is $h{'content-length'}, 2, 'content-length computed';
    is $events->[1]{type}, 'http.response.body', 'body second';
    is $events->[1]{body}, 'hi', 'body bytes';
    is $events->[1]{more}, 0, 'final chunk';
};

subtest 'a response value is reusable across connections (re-entrant)' => sub {
    my $res = PAGI::Response->new->_set_body('x', 'text/plain');
    my ($s1, $e1) = recorder();
    my ($s2, $e2) = recorder();
    $res->respond($s1)->get;
    $res->respond($s2)->get;
    is $e1->[1]{body}, 'x', 'first connection';
    is $e2->[1]{body}, 'x', 'second connection — same value, no leaked state';
};

subtest 'to_app wraps respond' => sub {
    my $res = PAGI::Response->new->_set_body('app', 'text/plain');
    my $app = $res->to_app;
    is ref($app), 'CODE', 'coderef';
    my ($send, $events) = recorder();
    $app->({}, sub { Future->done }, $send)->get;
    is $events->[1]{body}, 'app', 'mounted response serves its body';
};

subtest 'respond drives a stream callback' => sub {
    my $res = PAGI::Response->new->content_type('text/plain');
    $res->{_stream} = async sub {        # Task 3's stream($cb) will set this publicly
        my ($writer) = @_;
        await $writer->write('a');
        await $writer->write('b');
    };
    my ($send, $events) = recorder();
    $res->respond($send)->get;
    is $events->[0]{type}, 'http.response.start', 'start first';
    ok !(grep { lc($_->[0]) eq 'content-length' } @{$events->[0]{headers}}),
        'no content-length for a stream';
    my @body = grep { $_->{type} eq 'http.response.body' } @$events;
    is join('', map { $_->{body} // '' } @body), 'ab', 'chunks streamed';
    is $body[-1]{more}, 0, 'final chunk closes the stream';
};

subtest 'body methods set body and return self (class or instance)' => sub {
    my $res = PAGI::Response->new;
    ref_is $res->text('hi'), $res, 'instance text returns $self';

    my ($send, $events) = recorder();
    PAGI::Response->json({ ok => 1 })->respond($send)->get;
    my %h = map { lc($_->[0]) => $_->[1] } @{$events->[0]{headers}};
    like $h{'content-type'}, qr{application/json}, 'json content-type';
    like $events->[1]{body}, qr/"ok"\s*:\s*1/, 'json body';

    ($send, $events) = recorder();
    PAGI::Response->text('hello')->status(202)->respond($send)->get;
    is $events->[0]{status}, 202, 'factory value still chains status';
    is $events->[1]{body}, 'hello', 'text body';

    ($send, $events) = recorder();
    PAGI::Response->redirect('/login')->respond($send)->get;
    is $events->[0]{status}, 302, 'redirect default status';
    my %rh = map { lc($_->[0]) => $_->[1] } @{$events->[0]{headers}};
    is $rh{location}, '/login', 'redirect location';

    ($send, $events) = recorder();
    PAGI::Response->new->empty->respond($send)->get;
    is $events->[0]{status}, 204, 'empty default 204';
};

done_testing;
