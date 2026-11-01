use strict;
use warnings;
use Test2::V0;
use Future;

use lib 't/lib';
use PAGITest::Connected qw(ws_scope sse_scope);
use PAGI::WebSocket;
use PAGI::SSE;

# PAGI::WebSocket and PAGI::SSE share one internal base. The methods they
# had in identical copies live only there, so the two cannot drift apart.

my $BASE = 'PAGI::HTTPConnection::_Protocol';

my @shared = qw(
    buffered_amount high_water_mark low_water_mark
    on_high_water on_drain is_writable
    connection_state is_closed disconnect_detail
    on_close on_error finished
    try_send_json
    _refusing _answered_by_another _set_state
    _run_late_close_callback _run_close_callbacks _start_close_callbacks
    _keep
);

# Subclasses as an application writes them: new overridden, calling SUPER::.
package Local::WebSocket {
    our @ISA = ('PAGI::WebSocket');
    sub new { my $class = shift; return $class->SUPER::new(@_) }
}
package Local::SSE {
    our @ISA = ('PAGI::SSE');
    sub new { my $class = shift; return $class->SUPER::new(@_) }
}

my %type = ('PAGI::WebSocket' => 'websocket', 'PAGI::SSE' => 'sse');

ok($BASE->isa('PAGI::HTTPConnection'), 'the base is a PAGI::HTTPConnection');

for my $class (sort keys %type) {
    subtest "$class inherits the shared methods from the base" => sub {
        ok($class->isa($BASE), "$class isa $BASE");
        for my $method (@shared) {
            my $from_base = $BASE->can($method);
            ok($from_base, "the base defines $method")
                and ref_is($class->can($method), $from_base, "$class gets $method from the base");
        }
    };
}

my $file = __FILE__;

for my $class (sort keys %type) {
    my $type = $type{$class};
    my $subclass = 'Local::' . ($class =~ s/^PAGI:://r);

    for my $caller ($class, $subclass) {
        subtest "$caller->new: argument errors name $caller and the caller's line" => sub {
            my ($error, $line);

            $line = __LINE__; $error = dies { $caller->new };
            is($error, "$caller requires scope hashref at $file line $line.\n",
                'without a scope');

            $line = __LINE__; $error = dies { $caller->new({ type => $type }) };
            is($error, "$caller requires receive coderef at $file line $line.\n",
                'without receive');

            $line = __LINE__; $error = dies { $caller->new({ type => $type }, sub {}) };
            is($error, "$caller requires send coderef at $file line $line.\n",
                'without send');

            $line = __LINE__; $error = dies { $caller->new({ type => 'http' }, sub {}, sub {}) };
            is($error, "$caller requires scope type '$type', got 'http' at $file line $line.\n",
                'with another scope type');

            like(dies { $caller->new({ type => $type, headers => [] }, sub {}, sub {}) },
                qr/^\Q$caller\E requires pagi\.connection capabilities /,
                'without pagi.connection');
        };
    }

    subtest "$subclass is built through the base" => sub {
        my $scope = $type eq 'sse' ? sse_scope() : ws_scope();
        my $helper = $subclass->new($scope, sub { Future->new }, sub { Future->done });
        isa_ok($helper, [$subclass, $class, $BASE]);
        is($helper->connection_state, $type eq 'sse' ? 'pending' : 'connecting',
            'starts in its protocol\'s first state');
    };
}

done_testing;
