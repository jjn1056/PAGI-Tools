use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use PAGI::Middleware::Cookie;

# D5a: the cookie jar's set writes the value as is (RFC 6265 cookie-octets)
# and croaks on anything else.

sub run_jar {
    my ($code) = @_;
    my @sent;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $code->($scope->{'pagi.cookie_jar'});
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
    };
    my $wrapped = PAGI::Middleware::Cookie->new->wrap($app);
    $wrapped->({ type => 'http', headers => [] }, sub { Future->done }, sub { push @sent, $_[0]; Future->done })->get;
    return [ map { $_->[1] } grep { lc $_->[0] eq 'set-cookie' } @{ $sent[0]{headers} } ];
}

is run_jar(sub { $_[0]->set(a => 'x/y') }), ['a=x/y; path=/'], 'a slash is written as is';
is run_jar(sub { $_[0]->set(a => 'x%y', httponly => 1, samesite => 'Lax') }),
    ['a=x%y; path=/; SameSite=Lax; HttpOnly'], 'a percent sign is written as is, with attributes';

my $err;
run_jar(sub { my ($jar) = @_; $err = dies { $jar->set(a => q{x;y}) } });
like $err,
    qr/cookie value contains ';' which browsers cannot carry; encode it first \(Base64, say\)/,
    'a semicolon croaks';

is run_jar(sub { $_[0]->delete('a', domain => 'example.com') }),
    ['a=; domain=example.com; path=/; expires=Thu, 01-Jan-1970 00:00:00 GMT'],
    'delete writes an expired empty cookie';

done_testing;
