#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';
use PAGI::Compose qw(compose);
use PAGI::Response qw(text_response);
use PAGI::Routing qw(middleware mount route router sse websocket);

sub slurp_file {
    my ($file) = @_;
    open my $handle, '<', $file or die "Cannot read $file: $!";
    local $/;
    my $source = <$handle>;
    close $handle or die "Cannot close $file: $!";
    return $source;
}

sub cookbook_apples_block {
    my ($cookbook) = @_;
    my $heading = '=head2 Complete Declarative Apples Application';
    my $position = index $cookbook, $heading;
    die 'Complete Declarative Apples Application section not found'
        if $position < 0;
    my @lines = split /\n/, substr($cookbook, $position);
    my (@block, $started);
    for my $line (@lines) {
        if (!$started) {
            next unless $line eq '  use v5.40;';
            $started = 1;
        }
        last if length($line) && $line !~ /^  /;
        push @block, length($line) ? substr($line, 2) : '';
    }
    pop @block while @block && $block[-1] eq '';
    return join("\n", @block) . "\n";
}

my $cookbook = slurp_file('lib/PAGI/Tools/Cookbook.pod');

subtest 'canonical apples block stays synchronized with the runnable example' => sub {
    my $example = slurp_file('examples/starlette-apples/app.pl');
    $example =~ s/\A#![^\n]*\n//;
    is cookbook_apples_block($cookbook), $example,
        'the complete Cookbook block is the runnable apples source without its shebang';
};

subtest 'Cookbook publishes the complete declarative topology' => sub {
    like $cookbook,
        qr/Endpoint::HTTP\/WebSocket\/SSE.*?one exact route.*?Route.*?exact path.*?Mount.*?prefix.*?Router.*?ordered children.*?Compose.*?lifespan/is,
        'the five-layer topology appears in the Cookbook';
    like $cookbook, qr/route\('\/messages'\s*=>\s*MessageAPI->new/,
        'HTTP endpoint object is placed at one exact Route';
    like $cookbook, qr/websocket\('\/chat'\s*=>\s*ChatEndpoint->new/,
        'WebSocket endpoint object is placed at one exact Route';
    like $cookbook, qr/sse\('\/events'\s*=>\s*EventEndpoint->new/,
        'SSE endpoint object is placed at one exact Route';
    like $cookbook, qr/sub routing.*?return router\(/s,
        'ordinary object assembly returns an immutable Router';
    like $cookbook, qr/compose\(\s*routes\s*=>\s*\[/s,
        'Compose receives root routes directly';
    like $cookbook,
        qr/use PAGI::Utils qw\(app_path\).*?sub public_root.*?app_path\('public'\)/s,
        'app_path is called directly by the asset-owning module';
};

subtest 'representative final forms construct' => sub {
    my $factory = sub {
        my ($inner) = @_;
        return sub { return $inner->(@_) };
    };
    my $child = router(routes => [
        route('/' => sub { return text_response('child') }, name => 'index'),
    ]);
    my $root = compose(routes => [
        route('/health' => sub { return text_response('ok') },
            middleware => [middleware($factory)]),
        mount('/child', app => $child, name => 'child'),
        websocket('/chat' => sub { return $_[0]->close }),
        sse('/events' => sub { return $_[0]->close }),
    ]);
    isa_ok $child, 'PAGI::Routing::Router';
    isa_ok $root, 'PAGI::Compose';
    is $root->path_for('/child/index'), '/child/',
        'mounted child remains discoverable for reverse routing';
};

unlike $cookbook,
    qr/PAGI::(?:App|Endpoint)::Router|->to_router|middleware_as|app_as/,
    'Cookbook contains no removed frontend syntax';

done_testing;
