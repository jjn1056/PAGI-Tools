use strict;
use warnings;
use File::Basename qw(dirname);
use lib dirname(__FILE__) . '/lib';
use Future::AsyncAwait;
use PAGI::Routing qw(:ALL);
use PAGI::Middleware::Helpers qw(wrap_send);
use MyApp::Routes::Home ();

my $home_header = middleware(sub {
    my ($app) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $wrapped_send = wrap_send($send, async sub {
            my ($event, $downstream) = @_;
            if (($event->{type} // '') eq 'http.response.start') {
                $event = {
                    %$event,
                    headers => [
                        @{$event->{headers} // []},
                        ['x-route-demo', 'home'],
                    ],
                };
            }
            await $downstream->($event);
        });

        await $app->($scope, $receive, $wrapped_send);
    };
});

my $routing = router(
    desc => 'Declarative routing example',
    not_found => \&MyApp::Routes::Home::not_found,
    method_not_allowed => \&MyApp::Routes::Home::method_not_allowed,
    routes => [
        route('/' => \&MyApp::Routes::Home::home,
            name       => 'home',
            desc       => 'HTML home page',
            middleware => [$home_header],
        ),
        mount('/api',
            routes => [
                route('/items/{id}' => \&MyApp::Routes::Home::show_item,
                    name        => 'item',
                    desc        => 'Show one numeric item',
                    methods     => ['GET'],
                    constraints => { id => qr/\d+/ },
                ),
            ],
            namespace => 'api',
            desc      => 'Example JSON API',
        ),
    ],
);

$routing->to_app;
