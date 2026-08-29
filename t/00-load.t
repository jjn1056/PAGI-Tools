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
    PAGI::Routing::URL
    PAGI::Routing::Compiler
    PAGI::Routing::HeadBoundary
    PAGI::Middleware
    PAGI::Middleware::Helpers
    PAGI::Middleware::Builder
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
    PAGI::Request::BodyStream
    PAGI::Request::MultipartStream
    PAGI::State
    PAGI::CSRF
    PAGI::Transport
    PAGI::Request::Upload
    PAGI::Request::Negotiate
    PAGI::Response
    PAGI::Response::Text
    PAGI::Response::HTML
    PAGI::Response::JSON
    PAGI::Response::Problem
    PAGI::Response::Redirect
    PAGI::Response::Empty
    PAGI::Response::File
    PAGI::Response::File::Plan
    PAGI::Response::Stream
    PAGI::Response::Writer
    PAGI::Pages
    PAGI::Session
    PAGI::Stash
    PAGI::WebSocket
    PAGI::SSE
    PAGI::Lifespan
    PAGI::Utils
    PAGI::Utils::Scope
    PAGI::SendValidation
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

my @removed_modules = (
    join('::', qw(PAGI Routing Trace)),
    join('::', qw(PAGI Routing Trace Recorder)),
    join('::', qw(PAGI Routing Trace Snapshot)),
    join('::', qw(PAGI Middleware Routing), '_' . 'Fallback'),
    join('::', qw(PAGI Middleware Routing), 'Not' . 'Found'),
    join('::', qw(PAGI Middleware Routing), 'Method' . 'NotAllowed'),
);

for my $module (@removed_modules) {
    my $file = $module;
    $file =~ s{::}{/}g;
    $file .= '.pm';
    my $loaded = eval { require $file; 1 };
    ok(!$loaded, "$module is no longer loadable");
}

done_testing;
