#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

sub slurp_file {
    my ($file) = @_;
    open my $handle, '<', $file or die "Cannot read $file: $!";
    local $/;
    my $source = <$handle>;
    close $handle or die "Cannot close $file: $!";
    return $source;
}

my $upgrading = slurp_file('UPGRADING.md');

subtest 'upgrade guide publishes the declarative-only topology' => sub {
    like $upgrading, qr/## Breaking: remove the mutable Router frontends/,
        'the removal has a dedicated breaking-change section';
    like $upgrading,
        qr/Endpoint::HTTP\/WebSocket\/SSE.*?one exact route.*?Route.*?exact path.*?Mount.*?prefix.*?Router.*?ordered children.*?Compose.*?lifespan/is,
        'the five-layer responsibility model is explicit';
    like $upgrading, qr/no compatibility (?:layer|classes?)/i,
        'the guide states that no compatibility layer exists';
};

subtest 'App Router migration is complete' => sub {
    for my $concept (
        'verb methods', 'modifiers', 'middleware', 'mounts',
        'WebSocket and SSE', 'HTTP default', 'description',
        'nested URL',
    ) {
        like $upgrading, qr/\Q$concept\E/i, "guide covers $concept";
    }
    like $upgrading,
        qr/Before:.*?PAGI::App::Router.*?After:.*?PAGI::Routing/s,
        'App Router has a labelled Before and declarative After example';
};

subtest 'Endpoint Router migration is complete' => sub {
    for my $concept (
        'string method', 'to_router', 'middleware_as', 'app_as',
        'new_request', 'app_path', 'routing',
    ) {
        like $upgrading, qr/\Q$concept\E/i, "guide covers $concept";
    }
    like $upgrading,
        qr/Before:.*?PAGI::Endpoint::Router.*?After:.*?sub routing.*?router\(/s,
        'Endpoint Router has a labelled Before and ordinary assembler After';
};

subtest 'endpoint lifecycle and method policy are explicit' => sub {
    like $upgrading,
        qr/configured WebSocket and SSE.*?same (?:object|instance).*?concurrent/is,
        'configured protocol endpoint lifetime is documented';
    like $upgrading,
        qr/allowed_methods.*?once.*?Route construction/is,
        'one-time method capability snapshot is documented';
    like $upgrading,
        qr/methods\s*=>\s*'\*'.*?(?:bypass|endpoint owns)/is,
        'unrestricted method escape hatch is documented';
    like $upgrading,
        qr/OPTIONS.*?Allow.*?Router/is,
        'Router method-outcome ownership is documented';
};

subtest 'live public POD recommends only declarative routing' => sub {
    my @files = qw(
        lib/PAGI/Tools.pm
        lib/PAGI/Routing.pm
        lib/PAGI/Routing/Route.pm
        lib/PAGI/Routing/Mount.pm
        lib/PAGI/Routing/Router.pm
        lib/PAGI/Compose.pm
        lib/PAGI/Lifespan.pm
        lib/PAGI/Request.pm
        lib/PAGI/Tools/Tutorial.pod
        lib/PAGI/Tools/Cookbook.pod
    );
    for my $file (@files) {
        my $source = slurp_file($file);
        unlike $source,
            qr/PAGI::(?:App|Endpoint)::Router|->to_router|middleware_as|app_as/,
            "$file has no removed frontend recommendation";
    }
};

done_testing;
