package AppleApp::Middleware;

use v5.40;

use Exporter qw(import);
use Future::AsyncAwait;

use PAGI::Middleware::Helpers qw(wrap_send);

our @EXPORT_OK = qw(with_apples_api_header);

sub with_apples_api_header($app) {
    return async sub($scope, $receive, $send) {
        my $wrapped_send = wrap_send($send, async sub($event, $downstream) {
            if ($event->{type} eq 'http.response.start') {
                push @{$event->{headers}}, ['X-Apples-API', '1'];
            }
            return await $downstream->($event);
        });

        return await $app->($scope, $receive, $wrapped_send);
    };
}

1;
