#!/usr/bin/env perl
use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::Pages qw(not_found);
use PAGI::Utils qw(invoke_app);

print STDERR "Parent PID: $$\n";

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
    return await invoke_app(
        not_found(as => 'text'), $scope, $receive, $send,
    );
};

no warnings 'void';
$app;
