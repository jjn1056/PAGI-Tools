use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use lib 'lib';
use PAGI::Utils::Middleware qw(wrap_response_headers);

sub run_send {
    my ($wrapped, @events) = @_;
    $wrapped->($_)->get for @events;
}

subtest 'the editor works on a copy; a new event is sent' => sub {
    my @shared = (['content-type', 'text/plain'], ['x-keep', 'a']);
    my $start = { type => 'http.response.start', status => 200, headers => \@shared };
    my @sent;
    my $wrapped = wrap_response_headers(sub { push @sent, $_[0]; Future->done }, sub {
        my ($headers, $event) = @_;
        $headers->set('X-Runtime', '0.1');
        $headers->set('x-keep', 'b');
        is $event->{status}, 200, 'the editor sees the event';
    });
    run_send($wrapped, $start, $start);
    is \@shared, [['content-type', 'text/plain'], ['x-keep', 'a']], 'the sent array and pairs are untouched';
    isnt $sent[0], $start, 'a new event is sent';
    is $sent[1]{headers}, [['content-type', 'text/plain'], ['X-Runtime', '0.1'], ['x-keep', 'b']],
        'the second send of the same event gets exactly one of each';
};

subtest 'missing headers, async editors, other events' => sub {
    my @sent;
    my $wrapped = wrap_response_headers(sub { push @sent, $_[0]; Future->done }, async sub {
        my ($headers) = @_;
        await Future->done;
        $headers->add('Set-Cookie', 'a=1');
    });
    my $body = { type => 'http.response.body', body => 'x', more => 0 };
    run_send($wrapped, { type => 'http.response.start', status => 204 }, $body);
    is $sent[0]{headers}, [['Set-Cookie', 'a=1']], 'a start without headers gets the edits';
    is $sent[1], $body, 'a body event passes through as is';
};

subtest 'arguments are checked' => sub {
    like dies { wrap_response_headers(undef, sub {}) }, qr/send must be a coderef/;
    like dies { wrap_response_headers(sub {}, 'x') }, qr/editor must be a coderef/;
};

done_testing;
