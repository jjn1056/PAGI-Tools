use strict;
use warnings;
use Test2::V0;

# Modules covered for loadability: public entry points and selected internals
my @load_modules = qw(
    PAGI::Tools
    PAGI::Compose
    PAGI::Compose::Compiler
    PAGI::Exception::IncompleteResponse
    PAGI::Authority
    PAGI::Routing
    PAGI::Routing::Router
    PAGI::Routing::Route
    PAGI::Routing::Mount
    PAGI::Routing::Middleware
    PAGI::Routing::Pattern
    PAGI::Routing::Resolver
    PAGI::Routing::Compiler
    PAGI::Routing::HeadBoundary
    PAGI::Routing::Trace
    PAGI::Routing::Trace::Recorder
    PAGI::Routing::Trace::Snapshot
    PAGI::Middleware
    PAGI::Middleware::Helpers
    PAGI::Middleware::Builder
    PAGI::Middleware::Routing::NotFound
    PAGI::Middleware::Routing::MethodNotAllowed
    PAGI::App::Router
    PAGI::App::Router::Builder
    PAGI::App::Router::Materializer
    PAGI::App::File
    PAGI::App::File::Result
    PAGI::App::WrapPSGI
    PAGI::Endpoint::HTTP
    PAGI::Endpoint::Router
    PAGI::Endpoint::Router::Builder
    PAGI::Endpoint::SSE
    PAGI::Endpoint::WebSocket
    PAGI::Request
    PAGI::Request::Upload
    PAGI::Request::Negotiate
    PAGI::Response
    PAGI::Pages
    PAGI::Context
    PAGI::Session
    PAGI::Stash
    PAGI::WebSocket
    PAGI::SSE
    PAGI::Lifespan
    PAGI::Utils
    PAGI::Test::Client
    PAGI::Test::Response
);

for my $module (@load_modules) {
    my $file = $module;
    $file =~ s{::}{/}g;
    $file .= '.pm';
    my $loaded = eval { require $file; 1 };
    ok($loaded, "$module loads") or diag($@);
}

done_testing;
