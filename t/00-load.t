use strict;
use warnings;
use Test2::V0;

# Core modules that must always load
my @core_modules = qw(
    PAGI::Server
    PAGI::Server::Connection
    PAGI::Server::Protocol::HTTP1
    PAGI::Server::WebSocket
    PAGI::Server::SSE
    PAGI::Server::Lifespan
    PAGI::Server::Extensions::FullFlush
    PAGI::App::WrapPSGI
    PAGI::Request::Negotiate
    PAGI::Request::Upload
);

# Optional modules (TLS support)
my @optional_modules = qw(
    PAGI::Server::Extensions::TLS
);

# Test core modules
for my $module (@core_modules) {
    my $file = $module;
    $file =~ s{::}{/}g;
    $file .= '.pm';
    my $loaded = eval { require $file; 1 };
    ok($loaded, "load $module") or diag $@;
}

# Test optional modules (note if skipped)
SKIP: {
    my $tls_available = eval {
        require IO::Async::SSL;
        require IO::Socket::SSL;
        1;
    };

    skip "TLS modules not installed (optional)", scalar(@optional_modules)
        unless $tls_available;

    for my $module (@optional_modules) {
        my $file = $module;
        $file =~ s{::}{/}g;
        $file .= '.pm';
        my $loaded = eval { require $file; 1 };
        ok($loaded, "load $module (optional)") or diag $@;
    }
}

done_testing;
