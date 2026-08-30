use strict;
use warnings;

use Test2::V0;
use Future;

use PAGI::Pages;

{
    package Local::ProtocolGuardPages;
    our @ISA = ('PAGI::Pages');
    our $RENDER_COUNT = 0;

    sub render_text {
        my ($self, $page) = @_;
        ++$RENDER_COUNT;
        return $self->SUPER::render_text($page);
    }
}

sub invoke_capture {
    my ($app, $scope) = @_;
    my (@events, $receive_count);
    $receive_count = 0;
    my $receive = sub {
        ++$receive_count;
        return Future->done;
    };
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    my $error = dies {
        Future->wrap($app->($scope, $receive, $send))->get;
    };
    return ($error, \@events, $receive_count);
}

my $component = Local::ProtocolGuardPages->welcome(as => 'text');
isa_ok($component, ['PAGI::Pages::Application']);
my $app = $component->to_app;
is(ref($app), 'CODE', 'deferred Pages component compiles to a native app');

for my $type (qw(lifespan websocket sse unknown)) {
    local $Local::ProtocolGuardPages::RENDER_COUNT = 0;
    my ($error, $events, $receive_count) = invoke_capture(
        $app, { type => $type },
    );
    like($error, qr/PAGI::Pages.*requires HTTP scope.*\Q$type\E/i,
        "$type is rejected as an HTTP-only application decline");
    is($events, [], "$type rejection emits no protocol event");
    is($receive_count, 0, "$type rejection consumes no protocol event");
    is($Local::ProtocolGuardPages::RENDER_COUNT, 0,
        "$type rejection occurs before descriptor rendering");
}

my @http_events;
Future->wrap($app->(
    {
        type => 'http', method => 'GET', path => '/', headers => [],
        query_string => '', http_version => '1.1',
    },
    sub { Future->done },
    sub { push @http_events, $_[0]; Future->done },
))->get;
is($http_events[0]{status}, 200,
    'the same HTTP-only component serves an ordinary HTTP root invocation');

done_testing;
