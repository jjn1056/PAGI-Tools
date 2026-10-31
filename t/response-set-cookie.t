use strict;
use warnings;
use Test2::V0;
use PAGI::Response;

# D5a: Response->cookie writes the value as is (RFC 6265 cookie-octets) and
# croaks on anything else.

my $res = PAGI::Response->new('x');
$res->cookie(a => 'x/y');
is $res->header('set-cookie'), 'a=x/y; path=/', 'a slash is written as is';

$res = PAGI::Response->new('x');
$res->cookie(a => 'x%y', httponly => 1, secure => 1, samesite => 'Strict', max_age => 60);
is $res->header('set-cookie'), 'a=x%y; path=/; max-age=60; SameSite=Strict; secure; HttpOnly',
    'a percent sign is written as is, with the attributes';

$res = PAGI::Response->new('x');
like dies { $res->cookie(a => 'x;y') },
    qr/cookie value contains ';' which browsers cannot carry; encode it first \(Base64, say\)/,
    'a semicolon croaks';
ok !$res->has_header('set-cookie'), 'nothing was set';

$res = PAGI::Response->new('x');
$res->delete_cookie('a', path => '/x');
is $res->header('set-cookie'),
    'a=; path=/x; expires=Thu, 01-Jan-1970 00:00:00 GMT; max-age=0',
    'delete_cookie writes an expired empty cookie';

like dies { PAGI::Response->new('x')->cookie(a => undef) },
    qr/cookie value must be a string/, 'an undef value keeps Response\'s own refusal';

like dies { PAGI::Response->new('x')->cookie('a b' => 'v') },
    qr/\Acookie name contains ' ' which is not allowed in a cookie name at \Q$0\E line \d+/,
    'a bad name croaks at the caller';

for my $bad ('Laxity', 'bogus', '') {
    like dies { PAGI::Response->new('x')->cookie('a', 'v', samesite => $bad) },
        qr/\Asamesite must be Lax, Strict or None at \Q$0\E line \d+/,
        "samesite '$bad' croaks at the caller";
}
for my $case (['lax', 'Lax'], ['STRICT', 'Strict'], ['None', 'None; secure']) {
    is(PAGI::Response->new('x')->cookie('a', 'v', samesite => $case->[0])->header('set-cookie'),
        "a=v; path=/; SameSite=$case->[1]", "samesite $case->[0] is written");
}
is(PAGI::Response->new('x')->cookie('a', 'v')->header('set-cookie'),
    'a=v; path=/', 'no samesite writes none');

is(PAGI::Response->new('x')->cookie('widget', 'v', partitioned => 1)->header('set-cookie'),
    'widget=v; path=/; SameSite=None; secure; Partitioned',
    'partitioned forces SameSite=None and secure');
unlike(PAGI::Response->new('x')->cookie('widget', 'v', secure => 1)->header('set-cookie'),
    qr/Partitioned/, 'without partitioned there is no Partitioned attribute');

done_testing;
