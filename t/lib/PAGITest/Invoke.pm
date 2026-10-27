package PAGITest::Invoke;

use strict;
use warnings;
use Exporter 'import';
use Future;

our @EXPORT_OK = qw(invoke refresh);

# Runs a native app once with a captured send, so a test asserts on what the
# app actually did -- the events it sent and its own Future, settled or
# failed -- rather than on what PAGI::Test::Client makes of them (it hides
# exceptions by default and blanks HEAD bodies itself).
#
#   my $r = invoke($app, method => 'POST', path => '/x',
#       body_events => [{ type => 'http.request', body => 'a=1', more => 0 }]);
#   $r->{status}, $r->{headers}, $r->{body}, $r->{events}, $r->{future}
#
# Scope keys are given as named arguments; body_events are what receive
# delivers, then http.disconnect for every later call.
sub invoke {
    my ($app, %args) = @_;
    my @incoming = @{ delete($args{body_events}) // [] };
    my $scope = {
        type => 'http', method => 'GET', path => '/', raw_path => $args{path} // '/',
        query_string => '', headers => [], scheme => 'http',
        server => ['127.0.0.1', 5000], client => ['127.0.0.1', 12345],
        %args,
    };
    my @events;
    my $receive = sub { Future->done(@incoming ? shift @incoming : { type => 'http.disconnect' }) };
    my $send = sub { push @events, $_[0]; Future->done };
    my $future = Future->wrap($app->($scope, $receive, $send));
    return refresh({ events => \@events, future => $future });
}

# Re-reads status, headers and body from the events captured so far: for an
# app whose Future was still pending when invoke returned.
sub refresh {
    my ($r) = @_;
    my ($start) = grep { ($_->{type} // '') eq 'http.response.start' } @{ $r->{events} };
    $r->{status}  = $start ? $start->{status} : undef;
    $r->{headers} = $start ? $start->{headers} : undef;
    $r->{body}    = join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @{ $r->{events} };
    return $r;
}

1;
