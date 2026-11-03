use strict;
use warnings;
use Test2::V0;
use lib 'lib';
use PAGI::App::WrapPSGI;
use PAGI::Test::Client;

# A delayed PSGI response's writer is collected and sent when the app's
# responder callback returns, so WrapPSGI must not tell the app it may write
# later: psgi.streaming yes, psgi.nonblocking no.

my %env;
my $psgi = PAGI::App::WrapPSGI->new(psgi_app => sub {
    my ($e) = @_;
    %env = map { $_ => $e->{$_} } qw(psgi.streaming psgi.nonblocking);
    return sub {
        my ($respond) = @_;
        my $writer = $respond->([200, ['Content-Type' => 'text/plain']]);
        $writer->write($_) for qw(one two);
        $writer->close;
    };
});
my $res = PAGI::Test::Client->new(app => $psgi)->get('/');

is($res->status, 200, 'a delayed response is answered');
is($res->text, 'onetwo', 'writes made inside the responder callback are sent');
ok($env{'psgi.streaming'}, 'psgi.streaming is advertised');
ok(!$env{'psgi.nonblocking'}, 'psgi.nonblocking is not: later writes would be lost');

done_testing;
