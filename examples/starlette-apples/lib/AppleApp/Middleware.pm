package AppleApp::Middleware;

use v5.40;

use Exporter qw(import);
use Future::AsyncAwait;

use PAGI::Utils::Middleware qw(wrap_response_headers);

our @EXPORT_OK = qw(with_apples_api_header);

sub with_apples_api_header($app) {
    return async sub($scope, $receive, $send) {
        my $wrapped_send = wrap_response_headers($send, sub ($headers, $event) {
            $headers->set('X-Apples-API', '1');
        });

        return await $app->($scope, $receive, $wrapped_send);
    };
}

1;
