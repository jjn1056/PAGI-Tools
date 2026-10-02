#!/usr/bin/env perl
#
# A legacy PSGI application inside a PAGI-Tools application.
#
# PAGI::App::WrapPSGI adapts the PSGI app once; it then sits on an ordinary
# route beside native handlers. methods => '*' hands every HTTP method to it,
# as a PSGI app expects; the route is HTTP-only, so WebSocket and SSE requests
# never reach it.
#
# Run: pagi-server --app examples/psgi-bridge/app.pl --port 5000
#
use strict;
use warnings;
use PAGI::App::WrapPSGI;
use PAGI::Compose qw(compose);
use PAGI::Response qw(response);
use PAGI::Routing qw(route);

my $psgi_app = sub {
    my ($env) = @_;
    my $body = do { local $/; readline $env->{'psgi.input'} } // '';
    return [ 200, [ 'Content-Type' => 'text/plain' ], [ "PSGI says hi\n", "Body: $body" ] ];
};

compose(routes => [
    # New code is written natively...
    route('/health' => sub { return response('JSON', { ok => 1 }) }),
    # ...while everything else is still served by the PSGI application.
    route('/*path' => PAGI::App::WrapPSGI->new(psgi_app => $psgi_app), methods => '*'),
]);
