use strict;
use warnings;
use Test2::V0;
use PAGI::Utils qw(request_ended_abnormally);

# One discriminator for every component that observes response completeness.
#
# An application that stops early because its client disconnected is required
# NOT to send the terminal event (PAGI::Spec::Www, "Application Left a
# Response Incomplete"), so its event stream is indistinguishable from a buggy
# application's. Observers tell them apart by asking the request, not the
# events.

{
    package TestConn;
    sub new {
        my ($class, %args) = @_;
        return bless { reason => $args{reason} }, $class;
    }
    sub is_connected      { return $_[0]->{reason} ? 0 : 1 }
    sub disconnect_reason { return $_[0]->{reason} }
    sub on_disconnect     { return }
}

sub scope_with {
    my ($conn) = @_;
    return {
        type    => 'http',
        method  => 'GET',
        path    => '/',
        headers => [],
        (defined $conn ? ('pagi.connection' => $conn) : ()),
    };
}

is(request_ended_abnormally(scope_with(TestConn->new(reason => 'client_closed'))), 1,
    'a defined disconnect reason is an abnormal end');
is(request_ended_abnormally(scope_with(TestConn->new(reason => 'write_error'))), 1,
    'any standard reason counts');
is(request_ended_abnormally(scope_with(TestConn->new(reason => undef))), 0,
    'a connected request has not ended abnormally');
is(request_ended_abnormally(scope_with(undef)), 0,
    'a scope without pagi.connection is not an abnormal end');
is(request_ended_abnormally({ type => 'websocket' }), 0,
    'a non-http scope without a connection object is not an abnormal end');

# The discriminator is the reason, never is_connected on its own: a clean
# completion also clears is_connected, and those responses must still be
# validated. This is the distinction two components previously got wrong in
# incompatible ways.
{
    package CompletedConn;
    sub new               { return bless {}, shift }
    sub is_connected      { return 0 }
    sub disconnect_reason { return undef }
    sub on_disconnect     { return }
}
is(request_ended_abnormally(scope_with(CompletedConn->new)), 0,
    'a cleanly completed request is not an abnormal end');

# An empty reason string is not a reason.
{
    package EmptyReasonConn;
    sub new               { return bless {}, shift }
    sub is_connected      { return 0 }
    sub disconnect_reason { return '' }
    sub on_disconnect     { return }
}
is(request_ended_abnormally(scope_with(EmptyReasonConn->new)), 0,
    'an empty reason string does not count as an abnormal end');

# A connection object missing the accessor must not explode: pagi.connection
# is MUST-level for http scopes, but observers also run against test doubles
# and non-http scopes.
{
    package BareConn;
    sub new { return bless {}, shift }
}
is(request_ended_abnormally(scope_with(BareConn->new)), 0,
    'a connection object without disconnect_reason is handled safely');

# Defensive: a malformed scope must not die inside an observer's guard.
is(request_ended_abnormally(undef), 0, 'an undefined scope is not an abnormal end');
is(request_ended_abnormally('not a scope'), 0, 'a non-hashref scope is not an abnormal end');

# An unblessed hashref under pagi.connection is not a connection object.
is(request_ended_abnormally(scope_with({ disconnect_reason => 'client_closed' })), 0,
    'an unblessed hashref is not treated as a connection object');

done_testing;
