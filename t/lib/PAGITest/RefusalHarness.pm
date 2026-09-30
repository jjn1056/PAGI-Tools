package PAGITest::RefusalHarness;
use strict;
use warnings;
use Future;
use PAGI::Test::ConnectionState;
use PAGI::WebSocket;
use PAGI::SSE;

sub new {
    my ($class, $kind, %args) = @_;
    my $connection = PAGI::Test::ConnectionState->new(websocket => $kind eq 'websocket');
    my $events = [];
    my @input = @{ $args{input} || [] };
    my $scope = { type => $kind, method => 'POST', path => '/refuse', headers => [],
        pagi => { spec_version => '0.6' }, 'pagi.connection' => $connection };
    my $receive = sub { return Future->done(shift @input) };
    my $trailers;
    my $send = sub {
        my ($event) = @_;
        local $connection->{_defer_notifications} = 1;
        push @$events, $event;
        my $result = $args{send} ? $args{send}->($event) : Future->done;
        return $result if $result->is_failed;
        if ($event->{type} =~ /^(?:http\.response\.start|sse\.start|websocket\.accept)$/) {
            $connection->_mark_response_started;
            $trailers = $event->{trailers};
        }
        $connection->_mark_complete if
            ($event->{type} eq 'http.response.body' && !$event->{more} && !$trailers)
            || ($event->{type} eq 'http.response.trailers' && !$event->{more});
        return $result;
    };
    my $helper = ($kind eq 'websocket' ? 'PAGI::WebSocket' : 'PAGI::SSE')->new($scope, $receive, $send);
    return bless { scope => $scope, receive => $receive, send => $send,
        events => $events, connection => $connection, helper => $helper }, $class;
}
sub deliver { $_[0]{connection}->_deliver_notifications }
1;
