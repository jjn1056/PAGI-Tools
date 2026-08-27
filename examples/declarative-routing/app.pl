use strict;
use warnings;
use File::Basename qw(dirname);
use lib dirname(__FILE__) . '/lib';
use Future::AsyncAwait;
use PAGI::Compose qw(compose);
use PAGI::Pages;
use PAGI::Routing qw(:routes);
use PAGI::Middleware::Helpers qw(wrap_send);
use MyApp::Routes::Home ();

my $home_header = sub {
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
};

my $api_routing = router(
    routes => [
        route('/items/{id}' => \&MyApp::Routes::Home::show_item,
            name        => 'item',
            desc        => 'Show one numeric item',
            methods     => ['GET'],
            constraints => { id => qr/\d+/ },
        ),
    ],
    desc => 'Example JSON API',
    http_default => PAGI::Pages->not_found(
        detail => 'No API route matched'),
);

my $routing = router(
    desc => 'Declarative routing example',
    routes => [
        route('/' => \&MyApp::Routes::Home::home,
            name       => 'home',
            desc       => 'HTML home page',
            middleware => [$home_header],
        ),
        mount('/api',
            app  => $api_routing,
            name => 'api',
            desc => 'Example JSON API',
        ),
    ],
    http_default => PAGI::Pages->not_found(
        detail => 'No root route matched'),
);

compose(app => $routing);
