use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use lib 't/lib';
use PAGITest::Invoke qw(invoke);
use PAGI::Exception::HTTP;
use PAGI::Middleware::ErrorHandler;
use PAGI::Tools qw(compose middleware response route router);

# A thrown HTTP error, or a thrown page, whose status is 500 or more is
# answered as before -- by its catch entry or the built-in answer -- and then
# re-raised, so the server logs it: whoever throws a 500 means "this broke".
# on_error hears of it once. Below 500 a thrown error is an outcome: answered,
# not re-raised. An error a class entry answers is not re-raised either,
# whatever the entry's status.

package Local::Conflict { sub new { bless {}, shift } }

my @reported;
my %options = (
    on_error => sub { push @reported, ref($_[0]) || $_[0]; return },
    catch    => {
        'PAGI::Exception::HTTP' => sub { my ($request, $error) = @_; response('JSON', { error => $error->message }) },
        'Local::Conflict'       => sub { response('Text', 'busy', status => 503) },
    },
);

sub routes {
    return [
        route('/http-500'  => sub { PAGI::Exception::HTTP->throw(500, 'payment provider timed out') }),
        route('/http-503'  => sub { PAGI::Exception::HTTP->throw(503, 'down for a moment') }),
        route('/http-404'  => sub { PAGI::Exception::HTTP->throw(404, 'no such thing') }),
        route('/page-503'  => sub { die response('Text', 'maintenance', status => 503) }),
        route('/page-403'  => sub { die response('Text', 'no', status => 403) }),
        route('/class-503' => sub { die Local::Conflict->new }),
    ];
}

my %apps = (
    'Compose, a configured ErrorHandler' => compose(routes => routes(), middleware => [middleware('ErrorHandler', %options)])->to_app,
    'a bare wrap, around a Router'       => PAGI::Middleware::ErrorHandler->new(%options)->wrap(router(routes => routes())->to_app),
);

for my $placement (sort keys %apps) {
    subtest "$placement: 500 and up are answered, then re-raised" => sub {
        for my $case (
            ['/http-500', 500, '{"error":"Internal Server Error"}', 'PAGI::Exception::HTTP'],
            ['/http-503', 503, '{"error":"Service Unavailable"}',   'PAGI::Exception::HTTP'],
            ['/page-503', 503, 'maintenance',                       'PAGI::Response::Text'],
        ) {
            my ($path, $status, $body, $class) = @$case;
            @reported = ();
            my $r = invoke($apps{$placement}, path => $path);
            is [$r->{status}, $r->{body}], [$status, $body], "$path: its answer";
            is scalar(grep { $_->{type} eq 'http.response.start' } @{ $r->{events} }), 1, "$path: answered once";
            ok $r->{future}->is_failed, "$path: re-raised for the server";
            isa_ok(($r->{future}->failure)[0], [$class], "$path: the original");
            is \@reported, [$class], "$path: reported once";
        }
    };
    subtest "$placement: below 500, and class entries, are not re-raised" => sub {
        for my $case (['/http-404', 404, 'PAGI::Exception::HTTP'], ['/page-403', 403, 'PAGI::Response::Text'],
                      ['/class-503', 503, 'Local::Conflict']) {
            my ($path, $status, $class) = @$case;
            @reported = ();
            my $r = invoke($apps{$placement}, path => $path);
            is $r->{status}, $status, "$path: answered";
            ok $r->{future}->is_done, "$path: not re-raised";
            is \@reported, [$class], "$path: reported once";
        }
    };
}

subtest 'Compose with no ErrorHandler of its own: a thrown 500 is re-raised too' => sub {
    my $r = invoke(compose(routes => routes())->to_app, path => '/http-500');
    is [$r->{status}, $r->{body}], [500, 'Internal Server Error'];
    ok $r->{future}->is_failed, 're-raised';
    $r = invoke(compose(routes => routes())->to_app, path => '/http-404');
    ok $r->{future}->is_done, 'a thrown 404 is not';
};

done_testing;
