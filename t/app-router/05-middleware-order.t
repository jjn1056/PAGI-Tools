#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::App::Router::Builder ();
use PAGI::Routing qw(middleware);
use PAGI::Response ();
use PAGI::Test::Client ();

our ($CLASS_BUILD_TRACE, $CLASS_RUNTIME_TRACE);
BEGIN { $INC{'Local/TraceClass.pm'} = __FILE__ }
{
    package Local::TraceClass;

    sub new { return bless {}, $_[0] }
    sub wrap {
        my ($self, $inner) = @_;
        push @$main::CLASS_BUILD_TRACE, 'route class';
        return async sub {
            push @$main::CLASS_RUNTIME_TRACE, 'route class before';
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @$main::CLASS_RUNTIME_TRACE, 'route class after';
        };
    }
}

{
    package Local::TraceObject;

    sub new {
        my $class = shift;
        return bless { @_ }, $class;
    }
    sub wrap {
        my ($self, $inner) = @_;
        push @{$self->{build}}, $self->{label};
        my $trace = $self->{runtime};
        my $label = $self->{label};
        return async sub {
            push @$trace, "$label before";
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @$trace, "$label after";
        };
    }
}

sub trace_factory {
    my ($label, $build, $runtime) = @_;
    return sub {
        my ($inner) = @_;
        push @$build, $label;
        return async sub {
            push @$runtime, "$label before";
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @$runtime, "$label after";
        };
    };
}

sub body_header_factory {
    my ($header) = @_;
    return sub {
        my ($inner) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            my @events;
            my $capture = sub {
                push @events, $_[0];
                return Future->done;
            };
            my $returned = $inner->($scope, $receive, $capture);
            await Future->wrap($returned);
            my $bytes = 0;
            for my $event (@events) {
                $bytes += length($event->{body} || '')
                    if ($event->{type} || '') eq 'http.response.body';
            }
            for my $event (@events) {
                if (($event->{type} || '') eq 'http.response.start') {
                    $event = {
                        %$event,
                        headers => [@{$event->{headers} || []}, [$header => $bytes]],
                    };
                }
                await $send->($event);
            }
        };
    };
}

sub handler {
    my ($body, $counter, $trace) = @_;
    return sub {
        ++$$counter if $counter;
        push @$trace, 'handler' if $trace;
        return PAGI::Response->text($body);
    };
}

sub router_methods_exist {
    my ($builder) = @_;
    my $ok = 1;
    for my $method (qw(mount to_router to_app)) {
        $ok = 0 unless ok($builder->can($method), "Builder provides $method");
    }
    return $ok;
}

subtest 'explicit HEAD remains an ordinary declaration under one outer boundary' => sub {
    my ($head_first_calls, $get_after_calls) = (0, 0);
    my $head_first = PAGI::App::Router::Builder->new(
        middleware => [body_header_factory('X-Representation-Bytes')],
    );
    return unless router_methods_exist($head_first);
    $head_first->head('/item' => handler('HEAD', \$head_first_calls));
    $head_first->get('/item' => handler('GET-after', \$get_after_calls));
    my $head_first_client = PAGI::Test::Client->new(app => $head_first->to_app);
    my $explicit = $head_first_client->head('/item');
    is($explicit->header('X-Representation-Bytes'), 4,
        'HEAD-before-GET middleware observes the explicit HEAD representation body');
    is($explicit->content, '', 'the outer HeadBoundary suppresses the explicit body on wire');
    is([$head_first_calls, $get_after_calls], [1, 0],
        'explicit HEAD is the first FULL declaration and GET does not execute');
    is($head_first_client->get('/item')->text, 'GET-after',
        'the later GET remains the GET representation');

    my ($get_first_calls, $head_after_calls) = (0, 0);
    my $get_first = PAGI::App::Router::Builder->new(
        middleware => [body_header_factory('X-Representation-Bytes')],
    );
    $get_first->get('/item' => handler('GET-first', \$get_first_calls));
    $get_first->head('/item' => handler('HEAD-after', \$head_after_calls));
    my $get_first_client = PAGI::Test::Client->new(app => $get_first->to_app);
    my $get = $get_first_client->get('/item');
    my $automatic = $get_first_client->head('/item');
    is($automatic->header('X-Representation-Bytes'),
        $get->header('X-Representation-Bytes'),
        'GET-before-HEAD derives identical GET and HEAD representation headers');
    is($automatic->header('X-Representation-Bytes'), 9,
        'GET-before-HEAD middleware sees the full selected GET representation');
    is($automatic->content, '', 'automatic HEAD is suppressed only at the outer wire edge');
    is([$get_first_calls, $head_after_calls], [2, 0],
        'GET automatic HEAD is first FULL and the later explicit HEAD never executes');
};

subtest 'all levels preserve first-listed-outermost and build inner-to-outer' => sub {
    my (@build, @runtime);
    $CLASS_BUILD_TRACE = \@build;
    $CLASS_RUNTIME_TRACE = \@runtime;

    my $route_factory = trace_factory('route factory', \@build, \@runtime);
    my $route_object = Local::TraceObject->new(
        label => 'route object', build => \@build, runtime => \@runtime,
    );
    my $route_explicit = middleware(
        trace_factory('route explicit', \@build, \@runtime));

    my $child = PAGI::App::Router::Builder->new(
        middleware => [
            trace_factory('child Router first', \@build, \@runtime),
            trace_factory('child Router second', \@build, \@runtime),
        ],
    );
    return unless router_methods_exist($child);
    $child->get('/item' => [
        '^Local::TraceClass', $route_factory, $route_object, $route_explicit,
    ] => handler('ok', undef, \@runtime));

    my $root = PAGI::App::Router::Builder->new(
        middleware => [
            trace_factory('root Router first', \@build, \@runtime),
            trace_factory('root Router second', \@build, \@runtime),
        ],
    );
    $root->mount('/group',
        routes => sub {
            $_[0]->mount('/mount',
                app => $child->to_router,
                middleware => [
                    trace_factory('mount first', \@build, \@runtime),
                    trace_factory('mount second', \@build, \@runtime),
                ],
            )->name('child');
        },
        middleware => [
            trace_factory('callback Mount first', \@build, \@runtime),
            trace_factory('callback Mount second', \@build, \@runtime),
        ],
    );

    my $app = $root->to_app;
    is(\@build, [
        'route explicit', 'route object', 'route factory', 'route class',
        'child Router second', 'child Router first',
        'mount second', 'mount first',
        'callback Mount second', 'callback Mount first',
        'root Router second', 'root Router first',
    ], 'compile-time wrappers build from the innermost route outward');
    is(scalar(grep {
        $_ eq 'callback Mount first' || $_ eq 'callback Mount second'
    } @build), 2, 'each callback Mount middleware occurrence wraps exactly once');

    my $client = PAGI::Test::Client->new(app => $app);
    is($client->get('/group/mount/item')->text, 'ok',
        'the fully wrapped nested handler responds');
    is(\@runtime, [
        'root Router first before', 'root Router second before',
        'callback Mount first before', 'callback Mount second before',
        'mount first before', 'mount second before',
        'child Router first before', 'child Router second before',
        'route class before', 'route factory before',
        'route object before', 'route explicit before',
        'handler',
        'route explicit after', 'route object after',
        'route factory after', 'route class after',
        'child Router second after', 'child Router first after',
        'mount second after', 'mount first after',
        'callback Mount second after', 'callback Mount first after',
        'root Router second after', 'root Router first after',
    ], 'runtime order is first-listed-outermost at Router, both Mounts, and route');

    @runtime = ();
    is($client->get('/group/mount/item')->text, 'ok',
        'one compiled wrapper graph is reusable for another request');
    is(scalar(grep {
        $_ eq 'callback Mount first' || $_ eq 'callback Mount second'
    } @build), 2, 'requests never rebuild callback Mount middleware');
};

subtest 'outer native middleware may short circuit every inner level' => sub {
    my (@build, @runtime);
    my $outer = trace_factory('outer', \@build, \@runtime);
    my $short = sub {
        my ($inner) = @_;
        push @build, 'short';
        return async sub {
            my ($scope, $receive, $send) = @_;
            push @runtime, 'short';
            await $send->({
                type => 'http.response.start', status => 202,
                headers => [['content-type' => 'text/plain']],
            });
            await $send->({
                type => 'http.response.body', body => 'short', more => 0,
            });
        };
    };
    my $inner = trace_factory('must not execute', \@build, \@runtime);
    my $builder = PAGI::App::Router::Builder->new(
        middleware => [$outer, $short, $inner],
    );
    return unless router_methods_exist($builder);
    $builder->mount('/group',
        routes => sub {
            $_[0]->get('/item' => [
                trace_factory('route must not execute', \@build, \@runtime),
            ] => handler('handler', undef, \@runtime));
        },
        middleware => [
            trace_factory('Mount must not execute', \@build, \@runtime),
        ],
    );

    my $response = PAGI::Test::Client->new(app => $builder->to_app)
        ->get('/group/item');
    is([$response->status, $response->text], [202, 'short'],
        'the short circuit owns the response through native app-to-app middleware');
    is(\@runtime, ['outer before', 'short', 'outer after'],
        'no inner Router, Mount, route, or handler executes after short circuit');
};

done_testing;
