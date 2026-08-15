#!/usr/bin/env perl
use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use PAGI::Pages;

print STDERR "Parent PID: $$\n";

my $not_found = PAGI::Pages->not_found(as => 'text');

my $app = async sub {
    my ($scope, $receive, $send) = @_;

    if ($scope->{type} eq 'lifespan') {
        while (1) {
            my $event = await $receive->();
            my $type = $event->{type};

            if ($type eq 'lifespan.startup') {
                print STDERR "[$$] lifespan.startup\n";
                await $send->({ type => 'lifespan.startup.complete' });
            }
            elsif ($type eq 'lifespan.shutdown') {
                print STDERR "[$$] lifespan.shutdown\n";
                await $send->({ type => 'lifespan.shutdown.complete' });
                last;
            }
        }
        return;
    }

    # Default handler for HTTP
    return await Future->wrap($not_found->($scope, $receive, $send));
};

no warnings 'void';
$app;
