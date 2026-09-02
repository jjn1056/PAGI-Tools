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
my $routing = slurp_file('lib/PAGI/Routing.pm');

sub markdown_section {
    my ($source, $heading) = @_;
    my ($marks) = $heading =~ /\A(#+)/;
    my $heading_level = length $marks;
    my $start = index $source, $heading;
    die "section not found: $heading" if $start < 0;
    my @lines = split /\n/, substr($source, $start + length($heading));
    my @body;
    for my $line (@lines) {
        my ($next_marks) = $line =~ /\A(#+)\s/;
        last if defined($next_marks) && length($next_marks) <= $heading_level;
        push @body, $line;
    }
    return join "\n", @body;
}

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
    my $lifecycle = markdown_section(
        $upgrading, '### Configured WebSocket and SSE endpoint lifecycle');
    my $methods = markdown_section(
        $upgrading, '### HTTP endpoint method capability');

    like $lifecycle,
        qr/same object.*?concurrent/is,
        'configured protocol endpoint lifetime is documented';
    like $methods, qr/consults `allowed_methods` exactly.*?once.*?finite/is,
        'finite explicit methods consult one capability snapshot';
    like $methods, qr/finite.*?method.*?must be a restriction/is,
        'finite explicit methods must restrict the capability snapshot';
    like $methods,
        qr/only.*?scalar.*?methods\s*=>\s*'\*'.*?bypass/is,
        'unrestricted method escape hatch is documented';
    like $methods,
        qr/Router.*?(?:OPTIONS.*?Allow|Allow.*?OPTIONS)/is,
        'Router method-outcome ownership is documented';

    my ($route_docs) = $routing =~
        /=head2 route, websocket, sse\n(.*?)\n=head2 mount\n/s;
    ok defined $route_docs, 'the labelled Routing leaf section is present';
    like $route_docs,
        qr/explicit finite.*?consults.*?C<allowed_methods>.*?once.*?restriction/is,
        'Routing leaf docs state the same finite capability rule';
    like $route_docs,
        qr/Only scalar.*?methods => '\*'.*?bypasses/is,
        'Routing leaf docs reserve capability bypass for scalar star';
};

subtest 'Endpoint Router migration snippets own their helper imports' => sub {
    my $before = markdown_section(
        $upgrading, '### Migrate Endpoint Router classes');
    my ($removed, $after) = $before =~
        /(\*\*Before:.*?)(\*\*After:.*)\z/s;
    ok defined($removed) && defined($after),
        'labelled Endpoint Router Before and After snippets are present';
    like $removed, qr/use PAGI::Utils qw\(as_app\)/,
        'removed package imports as_app where its example calls it';
    like $after, qr/use PAGI::Routing qw\([^)]*\broute\b[^)]*\)/,
        'replacement package imports route where its example calls it';
    like $after, qr/use PAGI::Utils qw\([^)]*\bas_app\b[^)]*\)/,
        'replacement package imports as_app where its example calls it';
    my ($after_code) = $after =~ /```perl\n(.*?)```/s;
    ok defined $after_code, 'replacement code block can be extracted';
    eval $after_code;
    is $@, '', 'replacement packages compile independently as published';
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
            qr/PAGI::(?:App|Endpoint)::Router|\b(?:App|Endpoint) Router\b|->to_router|middleware_as|app_as/,
            "$file has no removed frontend recommendation";
    }
};

done_testing;
