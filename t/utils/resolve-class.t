use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Utils ();
use PAGI::Response qw(response);
use PAGI::Middleware::Session ();

# Every loader that takes a short name resolves it with _resolve_class:
# a leading '+' names a package exactly, a name inside the namespace is kept,
# the namespace root is itself, and anything else is prefixed.

for my $namespace ('PAGI::Response', 'PAGI::Middleware',
                   'PAGI::Middleware::Session::Store', 'PAGI::Middleware::Session::State') {
    subtest $namespace => sub {
        my $resolve = sub { PAGI::Utils::_resolve_class($namespace, $_[0], 'test') };
        is($resolve->($namespace), $namespace, 'the namespace root is itself');
        is($resolve->("${namespace}::Thing"), "${namespace}::Thing", 'a name inside it is kept');
        is($resolve->('Thing'), "${namespace}::Thing", 'a short name is prefixed');
        is($resolve->('+Other::Thing'), 'Other::Thing', 'a leading + is exact');
        is($resolve->('Other::Thing'), "${namespace}::Other::Thing", 'a :: name is still prefixed');
    };
}

subtest "response('PAGI::Response') builds the base class" => sub {
    my $r = response('PAGI::Response', 'bytes');
    is(ref $r, 'PAGI::Response', 'the base class');
    is($r->body, 'bytes', 'with its content');
};

subtest "a failed :: name suggests the leading +" => sub {
    my $error = dies { response('No::Such::Thing', 'x') };
    like($error, qr/\Aresponse\('No::Such::Thing'\): cannot load PAGI::Response::No::Such::Thing: /,
        'it names the call and the class tried');
    like($error, qr/for the package No::Such::Thing itself, write '\+No::Such::Thing'/, 'the hint');
    unlike($error, qr/\@INC entries checked/, 'without the @INC dump');

    $error = dies { PAGI::Middleware::Session::session_store('No::Such::Store') };
    like($error, qr/write '\+No::Such::Store'/, 'session_store too');

    like(dies { response('NoSuchThing', 'x') }, qr/Can't locate PAGI\/Response\/NoSuchThing\.pm/,
        'a name without :: keeps the ordinary message');
    like(dies { response('+No::Such::Thing', 'x') }, qr/Can't locate No\/Such\/Thing\.pm/,
        'an exact name keeps the ordinary message');
};

done_testing;
