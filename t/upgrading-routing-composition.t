#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Compose qw(compose);
use PAGI::Pages qw(not_found);
use PAGI::Response qw(text_response);
use PAGI::Routing qw(middleware mount route router);

sub slurp_file {
    my ($file) = @_;
    open my $handle, '<', $file or die "Cannot read $file: $!";
    local $/;
    my $source = <$handle>;
    close $handle or die "Cannot close $file: $!";
    return $source;
}

subtest 'current Compose and Router topology constructs' => sub {
    my $audit = sub {
        my ($inner) = @_;
        return sub { return $inner->(@_) };
    };
    my $child = router(
        desc => 'Child',
        http_default => not_found(detail => 'No child route'),
        middleware => [middleware($audit)],
        routes => [
            route('/{id}' => sub { return text_response($_[0]->path_param('id')) },
                name => 'show'),
        ],
    );
    my $app = compose(routes => [
        route('/' => sub { return text_response('home') }, name => 'home'),
        mount('/people', app => $child, name => 'people'),
    ]);
    isa_ok $app, 'PAGI::Compose';
    is $app->path_for('/people/show', { id => 42 }), '/people/42',
        'an immutable mounted Router remains discoverable';
    is $app->routes->[1]->app, $child,
        'the configured Router boundary is retained rather than flattened';
};

subtest 'public composition POD uses current ownership terms' => sub {
    my $compose = slurp_file('lib/PAGI/Compose.pm');
    my $routing = slurp_file('lib/PAGI/Routing.pm');
    like $compose, qr/Compose accepts only\s+C<routes>/,
        'Compose documents its one constructor grammar';
    like $compose, qr/mount\('\/people', app => \$people, name => 'people'\)/,
        'Compose documents a directly mounted immutable Router';
    like $routing, qr/=head1 RESPONSIBILITY BOUNDARIES/,
        'Routing documents the final responsibility split';
    like $routing, qr/Router.*?NONE\/PARTIAL outcomes/s,
        'Routing documents Router-owned routing outcomes';
};

subtest 'maintained examples use direct declarative assembly' => sub {
    for my $file (
        'examples/starlette-apples/app.pl',
        'examples/endpoint-demo/app.pl',
        'examples/endpoint-class-demo/app.pl',
        'examples/10-chat-showcase/app.pl',
    ) {
        my $source = slurp_file($file);
        unlike $source,
            qr/PAGI::(?:App|Endpoint)::Router|->to_router|middleware_as|app_as/,
            "$file has no removed frontend syntax";
    }
};

done_testing;
