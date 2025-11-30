use strict;
use warnings;
use Test2::V0;

# Test that all modules load correctly

my @modules = qw(
    PAGI::Server
    PAGI::Server::Connection
    PAGI::Server::Protocol::HTTP1
    PAGI::Server::WebSocket
    PAGI::Server::SSE
    PAGI::Server::Lifespan
    PAGI::Server::Scope
    PAGI::Server::Extensions::TLS
    PAGI::Server::Extensions::FullFlush
    PAGI::App::WrapPSGI
);

for my $module (@modules) {
    my $file = $module;
    $file =~ s{::}{/}g;
    $file .= '.pm';
    my $loaded = eval { require $file; 1 };
    ok($loaded, "load $module") or diag $@;
}

done_testing;
