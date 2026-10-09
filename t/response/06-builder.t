use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempfile);
use lib 't/lib';
use PAGI::Response qw(response);

subtest 'a short name builds the class of that name' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    print {$fh} "file body";
    close $fh;
    my $producer = sub { };
    my @cases = (
        ['Text',     ['hello'],              'PAGI::Response::Text'],
        ['HTML',     ['<b>x</b>'],           'PAGI::Response::HTML'],
        ['JSON',     [{ ok => \1 }],         'PAGI::Response::JSON'],
        ['Problem',  [{ title => 'Nope' }],  'PAGI::Response::Problem'],
        ['Redirect', ['/next'],              'PAGI::Response::Redirect'],
        ['Empty',    [status => 204],        'PAGI::Response::Empty'],
        ['File',     [$path],                'PAGI::Response::File'],
        ['Stream',   [$producer],            'PAGI::Response::Stream'],
        ['NDJSON',   [$producer],            'PAGI::Response::NDJSON'],
    );
    for my $case (@cases) {
        my ($name, $arguments, $class) = @$case;
        is(ref(response($name, @$arguments)), $class, "response('$name') is a $class");
    }
};

subtest 'the builder passes arguments through unchanged' => sub {
    my $built = response('Text', 'hello', status => 201, headers => ['X-A' => 'b']);
    my $direct = PAGI::Response::Text->new('hello', status => 201, headers => ['X-A' => 'b']);
    is($built->status, $direct->status, 'same status');
    is($built->body, $direct->body, 'same body bytes');
    is([$built->header_all('X-A')], [$direct->header_all('X-A')], 'same headers');
};

subtest 'a leading + names an exact class' => sub {
    my $xml = response('+PAGITest::XMLResponse', '<ok/>');
    isa_ok($xml, ['PAGITest::XMLResponse']);
    like($xml->content_type, qr{\Aapplication/xml}, 'its own content type');
    is(ref(response('+PAGI::Response', 'bytes')), 'PAGI::Response',
        'the base byte response is reachable exactly');
    is(ref(response('PAGI::Response::Text', 'hi')), 'PAGI::Response::Text',
        'a name already under the namespace is kept');
};

subtest 'errors name the problem' => sub {
    like(dies { response('json', {}) },
        qr/\Qresponse('json'): cannot load PAGI::Response::json:\E/,
        'a wrong-case name reports the class it tried to load');
    require PAGI::Response::JSON;
    my $error;
    my $warnings = warnings { $error = dies { response('json', {}) } };
    like($error, qr/\Qresponse('json'): cannot load\E/, 'refused even with JSON loaded');
    is($warnings, [], 'a wrong-case name never recompiles the loaded module');
    like(dies { response('NoSuchThing') },
        qr/\Qresponse('NoSuchThing'): cannot load PAGI::Response::NoSuchThing:\E/,
        'an unknown name reports the class it tried to load');
    like(dies { response('Writer') },
        qr/\Qresponse('Writer'): PAGI::Response::Writer is not a PAGI::Response\E/,
        'a helper under the namespace is refused');
    like(dies { response() }, qr/\Qresponse() requires a Response class name\E/, 'no name');
    like(dies { response(undef) }, qr/\Qresponse() requires a Response class name\E/, 'undef name');
    like(dies { response(['Text']) }, qr/\Qresponse() requires a Response class name\E/, 'reference name');
    like(dies { response('Text') }, qr/requires a body/,
        "a missing body is the constructor's own error");
};

subtest ':all exports response' => sub {
    package T::ResponseAllImport { PAGI::Response->import(':all') }
    ok(T::ResponseAllImport->can('response'), 'response is part of :all');
};

done_testing;
