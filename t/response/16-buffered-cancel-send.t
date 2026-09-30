use strict;
use warnings;

use Test2::V0;
use Future;
use PAGI::Response;
use PAGI::Utils qw(invoke_app);

for my $scope_type (qw(http websocket sse)) {
    subtest "$scope_type pending start send survives cancellation" => sub {
        my $pending = Future->new;
        my @events;
        my $operation = PAGI::Utils::invoke_app(
            PAGI::Response::text_response('no', status => 403),
            { type => $scope_type }, sub { die 'unexpected receive' },
            sub { push @events, $_[0]; return $pending },
        );
        $operation->cancel;
        ok($operation->is_cancelled, 'response invocation is cancelled');
        ok(!$pending->is_cancelled, 'server owns its submitted send');
        $pending->done;
        is([map { $_->{type} } @events], ['http.response.start'],
            'cancelled response never resumes to emit its body');
    };

    subtest "$scope_type pending body send survives cancellation" => sub {
        my $pending = Future->new;
        my @events;
        my $operation = invoke_app(
            PAGI::Response::text_response('no', status => 403),
            { type => $scope_type }, sub { die 'unexpected receive' },
            sub {
                push @events, $_[0];
                return Future->done if $_[0]{type} eq 'http.response.start';
                return $pending;
            },
        );
        is([map { $_->{type} } @events],
            ['http.response.start', 'http.response.body'],
            'start settlement submits the body');
        $operation->cancel;
        ok($operation->is_cancelled, 'response invocation is cancelled');
        ok(!$pending->is_cancelled, 'server owns its submitted send');
        $pending->done;
        is([map { $_->{type} } @events],
            ['http.response.start', 'http.response.body'],
            'cancelled response emits no additional event');
    };
}

subtest 'a normal send failure still fails invocation' => sub {
    my @events;
    my $operation = invoke_app(
        PAGI::Response::text_response('no', status => 403),
        { type => 'http' }, sub { die 'unexpected receive' },
        sub {
            push @events, $_[0];
            return Future->fail("send failed\n");
        },
    );
    like(dies { $operation->get }, qr/send failed/,
        'send failure propagates through invoke_app');
    is([map { $_->{type} } @events], ['http.response.start'],
        'body is not submitted after a failed start send');
};

done_testing;
