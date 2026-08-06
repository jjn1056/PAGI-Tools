package PAGI::Compose::Compiler;

use strict;
use warnings;
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use PAGI::Routing::Router ();
use PAGI::Utils ();

sub compile {
    my ($class, $description) = @_;
    croak 'compose description is required'
        unless blessed($description) && $description->isa('PAGI::Compose');

    my $target = $class->_compile_target($description);
    my $lifespan = $description->lifespan;
    my $dispatcher = async sub {
        my ($scope, $receive, $send) = @_;
        if (($scope->{type} // '') eq 'lifespan') {
            await $class->_run_lifespan($lifespan, $scope, $receive, $send);
            return;
        }

        my $returned = $target->($scope, $receive, $send);
        await Future->wrap($returned);
        return;
    };

    return $dispatcher;
}

sub _compile_target {
    my ($class, $description) = @_;
    my $routes = $description->routes;
    if (defined $routes) {
        return PAGI::Routing::Router->new(routes => $routes)->to_app;
    }
    return PAGI::Utils::to_app($description->app);
}

async sub _run_lifespan {
    my ($class, $lifespan, $scope, $receive, $send) = @_;

    while (1) {
        my $message = await Future->wrap($receive->());
        my $type = $message->{type} // '';
        if ($type eq 'lifespan.startup') {
            await Future->wrap($send->({ type => 'lifespan.startup.complete' }));
        }
        elsif ($type eq 'lifespan.shutdown') {
            await Future->wrap($send->({ type => 'lifespan.shutdown.complete' }));
            return;
        }
    }
}

1;
