#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use PAGI::Utils ();
use File::Temp qw(tempdir);
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Compose qw(compose);
use PAGI::Endpoint;
use PAGI::Response::Text ();
use PAGI::Routing qw(endpoint middleware mount route sse websocket);
use PAGI::Test::Client;
use PAGI::Tools ();

# endpoint('Class', %args) loads the class and builds it as the class
# decides. The classes are declared in this file, so most have no .pm file to
# require; the ones that do are written to a temporary directory.

package Local::Greeter {
    use parent 'PAGI::Endpoint::HTTP';
    use Scalar::Util qw(refaddr);
    our $BUILT = 0;

    sub new {
        my ($class, %args) = @_;
        $BUILT++;
        return $class->SUPER::new(%args);
    }

    sub get {
        my ($self, $request) = @_;
        return PAGI::Response::Text->new(
            ($self->{greeting} // 'hello') . ' from ' . refaddr($self));
    }
}

package Local::ArgsRecorder {
    use parent 'PAGI::Endpoint::HTTP';
    our @ARGS;

    sub new {
        my ($class, @args) = @_;
        @ARGS = @args;
        return $class->SUPER::new(@args);
    }
}

# BUILD_APP returning an object: that object answers every request.
package Local::GreeterBuiltOnce {
    use parent -norequire, 'Local::Greeter';
    our $CALLS = 0;

    sub BUILD_APP {
        my ($class, %args) = @_;
        $CALLS++;
        return $class->new(greeting => uc $args{greeting});
    }
}

# BUILD_APP may return any app object, not only an instance of the class.
package Local::Fixed {
    sub BUILD_APP { return PAGI::Response::Text->new('fixed answer') }
}

package Local::Echo {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    async sub on_receive {
        my ($self, $websocket, $text) = @_;
        await $websocket->send_text("$self->{prefix}$text");
    }
}

package Local::Ticker {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    async sub on_connect {
        my ($self, $sse) = @_;
        await $sse->send_event(data => $self->{first});
    }
}

# Keeps a value on $self, as NotesApp::Note does: right only when each request
# has its own object.
package Local::Memo {
    use parent 'PAGI::Endpoint::HTTP';

    sub get {
        my ($self, $request) = @_;
        $self->{seen} //= $request->query_param('id');
        return PAGI::Response::Text->new("id=$self->{seen}");
    }
}

# Counts messages on $self: right only when each connection has its own object.
package Local::Counter {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    async sub on_receive {
        my ($self, $websocket, $text) = @_;
        $self->{count}++;
        await $websocket->send_text("$self->{count}");
    }
}

package Local::SSEBuilt {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;
    our $BUILT = 0;

    sub new { my ($class, %args) = @_; $BUILT++; return $class->SUPER::new(%args) }

    async sub on_connect {
        my ($self, $sse) = @_;
        await $sse->send_event(data => 'hi');
    }
}

package Local::Neither {
    sub BUILD_APP { return 'oops' }
}

package Local::NewReturnsJunk {
    sub new { return {} }
}

package Local::OnlyHelper {
    sub helper { return 1 }
}

package Local::MooHealth {
    use Moo;
    extends 'PAGI::Endpoint::HTTP';
    has version => (is => 'ro', required => 1);
}

# BUILD_APP returning a builder: a fresh object per request, or a refusal.
package Local::Guarded {
    use parent -norequire, 'Local::Greeter';
    our $BUILDS = 0;

    sub BUILD_APP {
        my ($class, %args) = @_;
        return sub {
            my ($request) = @_;
            $BUILDS++;
            return PAGI::Response::Text->new('no token', status => 403)
                unless $request->header('X-Token');
            return $class->new(%args);
        };
    }
}

package Local::AppRequest {
    use parent 'PAGI::Request';
}

# Reports what its builder was given.
package Local::RequestReporter {
    use parent 'PAGI::Endpoint::HTTP';
    our @SEEN;

    sub BUILD_APP {
        my ($class, %args) = @_;
        return sub {
            my ($request) = @_;
            push @SEEN, [ref $request, $request->scope->{type}];
            return $class->new(%args);
        };
    }

    sub get { PAGI::Response::Text->new('reported') }
}

# A custom 405 hook on a per-request class.
package Local::Picky {
    use parent 'PAGI::Endpoint::HTTP';
    use PAGI::Response::JSON ();
    our $BUILDS = 0;

    sub BUILD_APP {
        my ($class, %args) = @_;
        return sub { $BUILDS++; return $class->new(%args) };
    }

    sub get { PAGI::Response::Text->new('picky get') }

    sub method_not_allowed {
        my ($self, $request, @allowed) = @_;
        return PAGI::Response::JSON->new(
            { error => 'nope', allowed => \@allowed }, status => 405);
    }
}

package Local::PerConnection {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;
    use Scalar::Util qw(refaddr);
    our @SEEN;

    sub BUILD_APP {
        my ($class, %args) = @_;
        return sub {
            my ($request) = @_;
            push @SEEN, [ref $request, $request->scope->{type}];
            return $class->new(%args);
        };
    }

    async sub on_connect {
        my ($self, $websocket) = @_;
        await $websocket->accept;
        await $websocket->send_text(refaddr($self));
    }
}

package Local::PerStream {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;
    use Scalar::Util qw(refaddr);
    our @SEEN;

    sub BUILD_APP {
        my ($class, %args) = @_;
        return sub {
            my ($request) = @_;
            push @SEEN, [ref $request, $request->scope->{type}];
            return $class->new(%args);
        };
    }

    async sub on_connect {
        my ($self, $sse) = @_;
        await $sse->send_event(data => refaddr($self));
    }
}

package Local::GuardedSocket {
    use parent 'PAGI::Endpoint::WebSocket';

    sub BUILD_APP {
        my ($class, %args) = @_;
        return sub {
            my ($request) = @_;
            return PAGI::Response::Text->new('no token', status => 403)
                unless $request->header('X-Token');
            return $class->new(%args);
        };
    }
}

package Local::GuardedStream {
    use parent 'PAGI::Endpoint::SSE';

    sub BUILD_APP {
        my ($class, %args) = @_;
        return sub {
            my ($request) = @_;
            return PAGI::Response::Text->new('no token', status => 403)
                unless $request->header('X-Token');
            return $class->new(%args);
        };
    }
}

package Local::AsyncBuilt {
    use parent -norequire, 'Local::Greeter';
    use Future::AsyncAwait;
    use Future::IO;

    sub BUILD_APP {
        my ($class, %args) = @_;
        return async sub {
            my ($request) = @_;
            await Future::IO->sleep(0);
            return PAGI::Response::Text->new('not yet', status => 401)
                unless $request->header('X-User');
            return $class->new(%args, greeting => 'hello ' . $request->header('X-User'));
        };
    }
}

# Its builder keeps the Request it was given, for the handler to compare
# with its own.
package Local::SameRequest {
    use parent 'PAGI::Endpoint::HTTP';
    use Scalar::Util qw(refaddr);

    sub BUILD_APP {
        my ($class, %args) = @_;
        return sub { my ($request) = @_; return $class->new(%args, built_with => $request) };
    }

    sub post {
        my ($self, $request) = @_;
        return PAGI::Response::Text->new(
            refaddr($self->{built_with}) == refaddr($request) ? 'same Request' : 'a different Request');
    }
}

package Local::BodyPeeker {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    sub BUILD_APP {
        my ($class, %args) = @_;
        return async sub {
            my ($request) = @_;
            my $data = await $request->json;
            return $class->new(%args, peeked => $data->{text});
        };
    }

    async sub post {
        my ($self, $request) = @_;
        my $data = await $request->json;
        return PAGI::Response::Text->new("$self->{peeked}/$data->{text}");
    }

    async sub put {
        my ($self, $request) = @_;
        $request->body_stream;
        return PAGI::Response::Text->new('streamed');
    }
}

package Local::Exploding {
    sub BUILD_APP { return sub { die "builder exploded\n" } }
}

package Local::JunkBuilder {
    sub BUILD_APP { return sub { return {} } }
}

package Local::AsyncFails {
    use Future::AsyncAwait;
    sub BUILD_APP {
        return async sub {
            await Future::IO->sleep(0);
            die "lookup failed\n";
        };
    }
}

package Local::AsyncJunk {
    use Future::AsyncAwait;
    sub BUILD_APP {
        return async sub {
            await Future::IO->sleep(0);
            return {};
        };
    }
}

package Local::MooPerRequest {
    use Moo;
    extends 'PAGI::Endpoint::HTTP';
    has user => (is => 'ro', required => 1);

    sub BUILD_APP {
        my ($class, %args) = @_;
        return sub { $class->new(%args) };
    }

    sub get { PAGI::Response::Text->new('never reached') }
}

# Moose without MooseX::NonMoose keeps the base's new, so these attributes
# would be ignored. No make_immutable, so Moose itself prints nothing.
package Local::PlainMoose {
    use Moose;
    extends 'PAGI::Endpoint::HTTP';
    has foo => (is => 'ro', required => 1);
}

package Local::MooseChild {
    use Moose;
    extends 'Local::PlainMoose';
}

package Local::MooseBuilder {
    use Moose;
    extends 'PAGI::Endpoint::HTTP';

    sub BUILD_APP {
        my ($class, %args) = @_;
        return sub { $class->new(%args) };
    }
}

# A framework that exports its own endpoint function.
package Local::FrameworkEndpoint {
    our @ISA = ('PAGI::Endpoint');
}

package Local::Framework {
    our @CARP_NOT = ('PAGI::Endpoint');
    sub endpoint { return Local::FrameworkEndpoint->new(@_)->endpoint }
}

package Local::FrameworkWithoutCarpNot {
    sub endpoint { return Local::FrameworkEndpoint->new(@_)->endpoint }
}

package Local::FixedEndpoint {
    our @ISA = ('PAGI::Endpoint');

    sub build { return PAGI::Response::Text->new('built by the subclass') }
}

package main;

# Compiling this call puts a 'helper' symbol in Local::Misspelt's stash, as a
# fully qualified call to a package nobody declared does.
sub never_called { return Local::Misspelt::helper() }

# Compiling these reads puts a symbol in each package's stash before its file
# is written and loaded below: endpoint() must still require the file.
sub never_reads { no warnings 'once'; return ($PAGITestTmp::Mentioned::DEBUG, $PAGITestTmp::MentionedBroken::DEBUG) }

my $lib = tempdir(CLEANUP => 1);
sub write_module {
    my ($path, $source) = @_;
    my @dirs = split m{/}, $path;
    pop @dirs;
    my $dir = $lib;
    for my $part (@dirs) {
        $dir .= "/$part";
        mkdir $dir unless -d $dir;
    }
    open my $fh, '>', "$lib/$path" or die "$path: $!";
    print {$fh} $source;
    close $fh or die "$path: $!";
}
write_module('PAGITestTmp/FileGreeter.pm', <<'PERL');
package PAGITestTmp::FileGreeter;
use parent 'PAGI::Endpoint::HTTP';
sub get { PAGI::Response::Text->new('from a file') }
1;
PERL
write_module('PAGITestTmp/HelperOnly.pm', <<'PERL');
package PAGITestTmp::HelperOnly;
sub helper { 1 }
1;
PERL
write_module('PAGITestTmp/Broken.pm', <<'PERL');
package PAGITestTmp::Broken;
sub new {
1;
PERL
unshift @INC, $lib;

my $this_file = __FILE__;

subtest 'without BUILD_APP each request gets a fresh object, with new and the arguments' => sub {
    $Local::Greeter::BUILT = 0;
    my $greeter = endpoint('Local::Greeter', greeting => 'hi');
    is($Local::Greeter::BUILT, 0, 'endpoint() builds nothing');
    isa_ok($greeter, ['PAGI::Endpoint::_PerRequest'], 'it returns the per-request wrapper');

    my $client = PAGI::Test::Client->new(
        app => compose(routes => [route('/greet' => $greeter)]));
    my @answers = map { $client->get('/greet')->text } 1 .. 2;
    like($_, qr/\Ahi from \d+\z/, 'with the arguments') for @answers;
    is($Local::Greeter::BUILT, 2, 'one object per request');
    isnt(($answers[0] =~ /(\d+)\z/)[0], ($answers[1] =~ /(\d+)\z/)[0], 'two objects');
};

subtest 'the arguments reach new unchanged and in order' => sub {
    my $repo = {};
    my $client = PAGI::Test::Client->new(app => compose(routes => [
        route('/' => endpoint('Local::ArgsRecorder', b => 2, a => 1, repo => $repo)),
    ]));
    $client->options('/');    # the class has no get: OPTIONS is what reaches it
    is(\@Local::ArgsRecorder::ARGS, [b => 2, a => 1, repo => exact_ref($repo)],
        'the same list, the same references, on each request');
};

subtest 'the same class at two routes keeps two configurations' => sub {
    my $app = compose(routes => [
        route('/en' => endpoint('Local::Greeter', greeting => 'hello')),
        route('/fr' => endpoint('Local::Greeter', greeting => 'bonjour')),
    ]);
    my $client = PAGI::Test::Client->new(app => $app);
    my ($en, $fr) = map { $client->get($_)->text } '/en', '/fr';
    like($en, qr/\Ahello from \d+\z/, 'one with its arguments');
    like($fr, qr/\Abonjour from \d+\z/, 'the other with its own');
};

subtest 'BUILD_APP returning an app object' => sub {
    $Local::GreeterBuiltOnce::CALLS = 0;
    my $app = compose(routes => [
        route('/once' => endpoint('Local::GreeterBuiltOnce', greeting => 'hi')),
        route('/fixed' => endpoint('Local::Fixed')),
    ]);
    is($Local::GreeterBuiltOnce::CALLS, 1, 'BUILD_APP runs once, when endpoint() is called');
    my $client = PAGI::Test::Client->new(app => $app);
    like($client->get('/once')->text, qr/\AHI from /, 'the object it built answers');
    like($client->get('/once')->text, qr/\AHI from /, 'every request');
    is($Local::GreeterBuiltOnce::CALLS, 1, 'and BUILD_APP is not called again');
    is($client->get('/fixed')->text, 'fixed answer',
        'any app object, not only an instance of the class');
};

subtest 'one spelling at route, websocket, sse and mount' => sub {
    my $app = compose(routes => [
        websocket('/echo' => endpoint('Local::Echo', prefix => 'echo: ')),
        sse('/ticks' => endpoint('Local::Ticker', first => 'tick')),
        mount('/mounted', app => endpoint('Local::Greeter', greeting => 'mounted')),
        route('/file' => endpoint('PAGITestTmp::FileGreeter')),
    ]);
    my $client = PAGI::Test::Client->new(app => $app);
    $client->websocket('/echo', sub {
        my ($ws) = @_;
        $ws->send_text('hi');
        is($ws->receive_text, 'echo: hi', 'websocket');
    });
    $client->sse('/ticks', sub {
        my ($sse) = @_;
        is($sse->receive_event->{data}, 'tick', 'sse');
    });
    $Local::Greeter::BUILT = 0;
    like($client->get('/mounted')->text, qr/\Amounted from /, 'mount');
    $client->get('/mounted');
    is($Local::Greeter::BUILT, 2, 'a mounted class is built per request too');
    is($client->get('/file')->text, 'from a file', 'a class with a file is loaded by name');
    ok($INC{'PAGITestTmp/FileGreeter.pm'}, 'which required it');
};

subtest 'mistakes fail at endpoint(), with their own messages' => sub {
    like(dies { endpoint() }, qr/\Aendpoint expects a class name at /, 'no class name');
    like(dies { endpoint('') }, qr/\Aendpoint expects a class name at /, 'an empty one');
    like(dies { endpoint(\'Local::Greeter') }, qr/\Aendpoint expects a class name at /,
        'a reference');
    like(dies { endpoint('Local::Greeter', 'greeting') },
        qr/\Aendpoint arguments must be key\/value pairs at /, 'an odd argument list');
    like(dies { endpoint('Bad Name') }, qr/\Ainvalid endpoint class name 'Bad Name' at /,
        'not a package name');
    like(dies { endpoint('Local::Neither') },
        qr/\ALocal::Neither->BUILD_APP must return an app object \(one with to_app\) or a coderef that builds one per request at /,
        'BUILD_APP returning a string');
};

subtest 'a class without BUILD_APP whose new fails answers that request with a 500' => sub {
    my $client = PAGI::Test::Client->new(app => compose(routes => [
        route('/junk' => endpoint('Local::NewReturnsJunk')),
        route('/moo'  => endpoint('Local::MooHealth')),
    ]));
    my %case = (
        '/junk' => qr/\Aexception after response completed: Local::NewReturnsJunk->new must return an app object \(one with to_app\); a native PAGI application goes through as_app_object\(\) at /,
        '/moo'  => qr/\Aexception after response completed: Missing required arguments: version at /,
    );
    # Local::MooHealth has no get, so a GET would be the Router's 405 and
    # build nothing; OPTIONS reaches the endpoint.
    my %method = ('/junk' => 'get', '/moo' => 'options');
    for my $path (sort keys %case) {
        my $res;
        my $call = $method{$path};
        like(warnings { $res = $client->$call($path) }, [$case{$path}], "$path: the error");
        is($res->status, 500, "$path: a 500");
    }
};

subtest 'an object that keeps state on $self answers each request with its own' => sub {
    my $client = PAGI::Test::Client->new(app => compose(routes => [
        route('/memo' => endpoint('Local::Memo')),
    ]));
    is([map { $client->get("/memo?id=$_")->text } 1, 2], ['id=1', 'id=2'],
        'the second request does not see the first one\'s value');
};

subtest 'WebSocket and SSE classes without BUILD_APP get one object per connection' => sub {
    $Local::SSEBuilt::BUILT = 0;
    my $client = PAGI::Test::Client->new(app => compose(routes => [
        websocket('/count' => endpoint('Local::Counter')),
        sse('/sse' => endpoint('Local::SSEBuilt')),
    ]));
    for my $connection (1, 2) {
        $client->websocket('/count', sub {
            my ($ws) = @_;
            $ws->send_text('x') for 1, 2;
            is([$ws->receive_text, $ws->receive_text], ['1', '2'], "connection $connection counts from 1");
        });
    }
    $client->sse('/sse', sub { is($_[0]->receive_event->{data}, 'hi', 'sse') }) for 1, 2;
    is($Local::SSEBuilt::BUILT, 2, 'one SSE object per connection');
};

subtest 'the default path builds no Request of its own' => sub {
    my $made = 0;
    no warnings 'redefine';
    my $original = \&PAGI::Utils::request_for_scope;
    local *PAGI::Utils::request_for_scope = sub { $made++; goto &$original };
    my $client = PAGI::Test::Client->new(app => compose(routes => [
        route('/plain' => endpoint('Local::Greeter')),
        route('/built' => endpoint('Local::Guarded', greeting => 'hi')),
    ]));
    $client->get('/plain');
    is($made, 1, 'no BUILD_APP: one Request, the endpoint\'s own');
    $made = 0;
    $client->get('/built', headers => { 'X-Token' => 'yes' });
    is($made, 1, 'a builder: one Request, the builder\'s, which the endpoint answers with');
};

subtest 'a class that cannot be loaded' => sub {
    my $line = __LINE__ + 1;
    my $error = dies { PAGI::Endpoint->new('No::Such::Endpoint')->endpoint };
    like($error,
        qr/\Aendpoint\('No::Such::Endpoint'\): cannot load No::Such::Endpoint: Can't locate No\/Such\/Endpoint\.pm in \@INC/,
        'an unknown class');
    my @locations = $error =~ / at (\S+) line (\d+)\./g;
    is(\@locations, [$this_file, $line], 'one location: the line that asked for it');

    like(dies { endpoint('PAGITestTmp::Broken') },
        qr/\Aendpoint\('PAGITestTmp::Broken'\): cannot load PAGITestTmp::Broken: .*Compilation failed in require/s,
        'a file that does not compile');
};

subtest 'a class with a file loads even if compiled code named one of its symbols' => sub {
    write_module('PAGITestTmp/Mentioned.pm', <<'PERL');
package PAGITestTmp::Mentioned;
use parent 'PAGI::Endpoint::HTTP';
sub get { return PAGI::Response::Text->new('mentioned') }
1;
PERL
    my $app;
    ok(lives { $app = endpoint('PAGITestTmp::Mentioned') }, 'the file is required');
    is(PAGI::Test::Client->new(app => compose(routes => [route('/' => $app)]))->get('/')->text,
        'mentioned', 'and the class answers');

    write_module('PAGITestTmp/MentionedBroken.pm', "package PAGITestTmp::MentionedBroken;\nsub new {\n1;\n");
    like(dies { endpoint('PAGITestTmp::MentionedBroken') },
        qr/\Aendpoint\('PAGITestTmp::MentionedBroken'\): cannot load PAGITestTmp::MentionedBroken: /,
        'a file that does not compile is a load error, not "has neither"');
};

subtest 'a class with neither new nor BUILD_APP' => sub {
    like(dies { endpoint('PAGITestTmp::HelperOnly') },
        qr/\Aendpoint class PAGITestTmp::HelperOnly has neither new nor BUILD_APP at /,
        'from its file');
    like(dies { endpoint('Local::OnlyHelper') },
        qr/\Aendpoint class Local::OnlyHelper has neither new nor BUILD_APP at /,
        'declared inline: the shape check, not a load error');
    like(dies { endpoint('Local::Misspelt') },
        qr/\Aendpoint class Local::Misspelt has neither new nor BUILD_APP at /,
        'a name some compiled code already used as a package reads as defined');
};

subtest 'BUILD_APP returning a builder: one object per request' => sub {
    $Local::Guarded::BUILDS = 0;
    $Local::Greeter::BUILT = 0;
    my $guarded = endpoint('Local::Guarded', greeting => 'welcome in');
    isa_ok($guarded, ['PAGI::Endpoint::_PerRequest::HTTP'], 'endpoint() returns the wrapper');
    is($Local::Guarded::BUILDS, 0, 'nothing is built until a request arrives');

    my $client = PAGI::Test::Client->new(
        app => compose(routes => [route('/guarded' => $guarded)]));
    my $refused = $client->get('/guarded');
    is([$refused->status, $refused->text], [403, 'no token'],
        'a builder may return a Response that refuses the request');
    my @answers = map {
        $client->get('/guarded', headers => { 'X-Token' => 1 })->text
    } 1 .. 2;
    like($answers[0], qr/\Awelcome in from \d+\z/, 'with a token it builds the endpoint');
    isnt($answers[0], $answers[1], 'a fresh object for each request');
    is([$Local::Guarded::BUILDS, $Local::Greeter::BUILT], [3, 2],
        'the builder ran per request; new ran when it was asked to');

    my $put = $client->put('/guarded', headers => { 'X-Token' => 1 });
    is([$put->status, $put->header('Allow')], [405, 'GET, HEAD, OPTIONS'],
        "PUT: the Router answers the 405 from the class's methods");
    is($Local::Guarded::BUILDS, 3, 'and the builder was not called for it');
};

subtest "the route asks the class for its methods" => sub {
    my $http = endpoint('Local::Guarded');
    is([$http->allowed_methods], [qw(GET HEAD OPTIONS)], 'the HTTP wrapper asks the class');
    is(route('/g' => $http)->methods, [qw(GET HEAD OPTIONS)], 'and route() snapshots it');
    is(route('/g' => $http, methods => 'GET')->methods, [qw(GET HEAD)],
        'a finite methods option narrows it');
    like(dies { route('/g' => $http, methods => 'PUT') },
        qr/\Amethods \[PUT\] are not advertised by route endpoint allowed_methods/,
        'and may not widen it');

    my $ws = endpoint('Local::PerConnection');
    isa_ok($ws, ['PAGI::Endpoint::_PerRequest'], 'a WebSocket class gets the plain wrapper');
    ok(!$ws->can('allowed_methods'), 'which has no allowed_methods');
};

subtest 'the builder gets the Request: HTTP, WebSocket and SSE' => sub {
    @Local::RequestReporter::SEEN = @Local::PerConnection::SEEN = @Local::PerStream::SEEN = ();
    my $routes = [
        route('/report' => endpoint('Local::RequestReporter')),
        websocket('/ws' => endpoint('Local::PerConnection')),
        sse('/events' => endpoint('Local::PerStream')),
    ];
    my $client = PAGI::Test::Client->new(app => compose(routes => $routes));
    $client->get('/report');
    is(\@Local::RequestReporter::SEEN, [['PAGI::Request', 'http']], 'HTTP: a PAGI::Request');

    my @objects;
    for (1 .. 2) {
        $client->websocket('/ws', sub { push @objects, $_[0]->receive_text });
    }
    is(\@Local::PerConnection::SEEN, [(['PAGI::Request', 'websocket']) x 2],
        'WebSocket: a PAGI::Request, once per connection');
    isnt($objects[0], $objects[1], 'and each connection has its own object');

    @objects = ();
    for (1 .. 2) {
        $client->sse('/events', sub { push @objects, $_[0]->receive_event->{data} });
    }
    is(\@Local::PerStream::SEEN, [(['PAGI::Request', 'sse']) x 2],
        'SSE: a PAGI::Request, once per connection');
    isnt($objects[0], $objects[1], 'and each connection has its own object');

    @Local::RequestReporter::SEEN = ();
    my $with_class = PAGI::Test::Client->new(app => compose(
        middleware => [middleware('RequestClass', class => 'Local::AppRequest')],
        routes     => [route('/report' => endpoint('Local::RequestReporter'))],
    ));
    $with_class->get('/report');
    is(\@Local::RequestReporter::SEEN, [['Local::AppRequest', 'http']],
        'below RequestClass: the application\'s class');
};

subtest 'a WebSocket or SSE builder may refuse with a Response' => sub {
    my $client = PAGI::Test::Client->new(app => compose(routes => [
        websocket('/ws' => endpoint('Local::GuardedSocket')),
        sse('/events' => endpoint('Local::GuardedStream')),
    ]));
    my $ws = $client->websocket('/ws');
    is([$ws->refused, $ws->response->status, $ws->response->text], [1, 403, 'no token'],
        'WebSocket: the handshake is refused with it');
    my $sse = $client->sse('/events');
    is([$sse->status, $sse->text], [403, 'no token'], 'SSE: the stream is refused with it');
    $client->websocket('/ws', headers => { 'X-Token' => 1 }, sub {
        my ($accepted) = @_;
        ok(!$accepted->refused, 'with a token the WebSocket endpoint is built');
    });
};

subtest "who answers a method the class does not have" => sub {
    $Local::Picky::BUILDS = 0;
    my $client = PAGI::Test::Client->new(app => compose(routes => [
        route('/picky' => endpoint('Local::Picky')),
        route('/star' => endpoint('Local::Picky'), methods => '*'),
        mount('/mounted', app => endpoint('Local::Picky')),
    ]));
    my $res = $client->put('/picky');
    is([$res->status, $res->text, $res->header('Allow')],
        [405, 'Method Not Allowed', 'GET, HEAD, OPTIONS'],
        'routed: the Router answers; the hook does not run');
    is($Local::Picky::BUILDS, 0, 'and nothing was built');

    for my $path ('/star', '/mounted') {
        $res = $client->put($path);
        is([$res->status, $res->json, $res->header('Allow')],
            [405, { error => 'nope', allowed => [qw(GET HEAD OPTIONS)] }, 'GET, HEAD, OPTIONS'],
            "$path: the built object's method_not_allowed answers");
    }
    is($Local::Picky::BUILDS, 2, 'the builder ran for each');
};

subtest 'a 405 for a class without BUILD_APP builds no object' => sub {
    $Local::Greeter::BUILT = 0;
    my $client = PAGI::Test::Client->new(app => compose(routes => [
        route('/greet' => endpoint('Local::Greeter')),
    ]));
    is($client->put('/greet')->status, 405, 'the Router answers from the class');
    is($Local::Greeter::BUILT, 0, 'and nothing was built');
};

subtest 'a builder may be async' => sub {
    my $client = PAGI::Test::Client->new(app => compose(routes => [
        route('/async' => endpoint('Local::AsyncBuilt')),
        route('/peek' => endpoint('Local::BodyPeeker')),
    ]));
    like($client->get('/async', headers => { 'X-User' => 'ada' })->text,
        qr/\Ahello ada from \d+\z/, 'it awaits, then returns the object');
    my $res = $client->get('/async');
    is([$res->status, $res->text], [401, 'not yet'], 'or a refusal');

    is($client->post('/peek', json => { text => 'milk' })->text, 'milk/milk',
        'a builder that read the body leaves the handler json: the same Request');
    my $streamed;
    like(warnings { $streamed = $client->put('/peek', json => { text => 'milk' }) },
        [qr/\Aexception after response completed: Body already consumed; streaming not available/],
        'but not body_stream');
    is($streamed->status, 500, '... a 500');
};

subtest "the handler gets the Request its builder was given" => sub {
    my $client = PAGI::Test::Client->new(app => compose(routes => [
        route('/same' => endpoint('Local::SameRequest')),
    ]));
    is($client->post('/same', body => '')->text, 'same Request', 'one Request per request');
};

# A subclass whose built object wraps its own to_app: the hand-off of the
# builder's Request must not skip it.
package Local::WrappedSameRequest {
    use parent -norequire, 'Local::SameRequest';
    use Future::AsyncAwait;
    our $wrapped = 0;
    sub to_app {
        my ($self) = @_;
        return $self->SUPER::to_app unless ref $self;
        my $inner = $self->SUPER::to_app;
        return async sub { $wrapped++; await $inner->(@_) };
    }
}

subtest "the builder's Request reaches the handler through the endpoint's own to_app" => sub {
    my $app = endpoint('Local::SameRequest')->to_app;
    like(dies { $app->({ type => 'websocket', path => '/', headers => [] },
            sub { die 'unexpected receive' }, sub { die 'unexpected send' })->get },
        qr/PAGI::Endpoint::HTTP requires HTTP scope; received 'websocket'/,
        'a websocket scope is refused, as without a builder');
    local $Local::WrappedSameRequest::wrapped = 0;
    my $client = PAGI::Test::Client->new(app => compose(routes => [
        route('/wrapped' => endpoint('Local::WrappedSameRequest')),
    ]));
    is($client->post('/wrapped', body => '')->text, 'same Request', 'still the same Request');
    is($Local::WrappedSameRequest::wrapped, 1, "and the built object's to_app ran");
};

subtest 'a builder that fails answers that request with a 500' => sub {
    my $client = PAGI::Test::Client->new(app => compose(routes => [
        route('/explodes' => endpoint('Local::Exploding')),
        route('/junk' => endpoint('Local::JunkBuilder')),
        route('/async-fails' => endpoint('Local::AsyncFails')),
        route('/async-junk' => endpoint('Local::AsyncJunk')),
        route('/moo' => endpoint('Local::MooPerRequest')),
    ]));
    my %case = (
        '/explodes'    => qr/\Aexception after response completed: builder exploded$/,
        '/junk'        => qr/\Aexception after response completed: Local::JunkBuilder->BUILD_APP's builder must return an app object \(one with to_app\); a native PAGI application goes through as_app_object\(\) at /,
        '/async-fails' => qr/\Aexception after response completed: lookup failed$/,
        '/async-junk'  => qr/\Aexception after response completed: Local::AsyncJunk->BUILD_APP's builder must return an app object \(one with to_app\); a native PAGI application goes through as_app_object\(\) at /,
        '/moo'         => qr/\Aexception after response completed: Missing required arguments: user at /,
    );
    for my $path (sort keys %case) {
        my $res;
        like(warnings { $res = $client->get($path) }, [$case{$path}], "$path: the error");
        is($res->status, 500, "$path: a 500");
    }
};

SKIP: {
    skip 'a signature needs Perl 5.36', 1 if $] < 5.036;
    subtest 'a native application returned from BUILD_APP is called as a builder' => sub {
        eval q{
            package Local::NativeByMistake;
            use v5.36;
            use Future::AsyncAwait;
            sub BUILD_APP ($class, %args) {
                return async sub ($scope, $receive, $send) {
                    await $send->({ type => 'http.response.start', status => 200, headers => [] });
                };
            }
            1;
        } or die $@;
        my $client = PAGI::Test::Client->new(
            app => compose(routes => [route('/native' => endpoint('Local::NativeByMistake'))]));
        my $res;
        like(warnings { $res = $client->get('/native') },
            [qr/\Aexception after response completed: Too few arguments for subroutine 'Local::NativeByMistake::__ANON__' \(got 1; expected 3\)/],
            "Perl's arity error, on the first request");
        is($res->status, 500, '... a 500');
    };
}

subtest 'a Moose class without MooseX::NonMoose is refused at endpoint()' => sub {
    my $expected = 'is a Moose class whose new is not Moose\'s, so its attributes'
        . ' (required, default, BUILD) would be ignored; add "use MooseX::NonMoose"'
        . ' after "use Moose"';
    for my $class (qw(Local::PlainMoose Local::MooseChild Local::MooseBuilder)) {
        my $line = __LINE__ + 1;
        like(dies { endpoint($class, foo => 1) },
            qr/\Aendpoint class \Q$class $expected\E at \Q$this_file\E line $line\.$/,
            "$class, at the line that named it");
    }
    ok(lives { endpoint('Local::MooHealth', version => '1.0') },
        'a Moo class is not mistaken for one with Moose loaded');
};

subtest 'load errors name the line that called endpoint' => sub {
    my $line = __LINE__ + 1;
    my $error = dies { endpoint('Bad Name') };
    like($error, qr/ at \Q$this_file\E line $line\.$/, 'through PAGI::Routing');

    $line = __LINE__ + 1;
    $error = dies { PAGI::Tools::endpoint('No::Such::Endpoint') };
    my @locations = $error =~ / at (\S+) line (\d+)\./g;
    is(\@locations, [$this_file, $line], 'through PAGI::Tools, with one location');

    $line = __LINE__ + 1;
    $error = dies { Local::Framework::endpoint('Bad Name') };
    like($error, qr/ at \Q$this_file\E line $line\.$/,
        "a framework's own endpoint with \@CARP_NOT = ('PAGI::Endpoint')");

    $error = dies { Local::FrameworkWithoutCarpNot::endpoint('Bad Name') };
    unlike($error, qr/ at \Q$this_file\E line $line\.$/,
        'without it the error names the framework\'s line instead');
};

subtest 'to_app is called on an endpoint object, not on a class name' => sub {
    for my $class (qw(Local::Greeter Local::Echo Local::Ticker)) {
        my $line = __LINE__ + 1;
        like(dies { $class->to_app },
            qr/\Ato_app is called on an endpoint object; use endpoint\('\Q$class\E'\) or \Q$class\E->new->to_app at \Q$this_file\E line $line\.$/,
            "$class->to_app dies");
        is(ref($class->new->to_app), 'CODE', "$class->new->to_app is the application");
    }
};

subtest 'the steps are methods a subclass may override' => sub {
    my $endpoint = PAGI::Endpoint->new('Local::Greeter', greeting => 'hi');
    is($endpoint->class, 'Local::Greeter', 'class');
    is([$endpoint->args], [greeting => 'hi'], 'args');

    my $app = Local::FixedEndpoint->new('Local::Greeter')->endpoint;
    is(PAGI::Test::Client->new(app => $app)->get('/')->text, 'built by the subclass',
        'an overridden build answers, per request, for a class without BUILD_APP');
};

subtest 'endpoint is exported by PAGI::Routing and PAGI::Tools' => sub {
    ok(\&PAGI::Tools::endpoint == \&PAGI::Routing::endpoint, 'one sub');
    ok((grep { $_ eq 'endpoint' } @{ $PAGI::Routing::EXPORT_TAGS{all} }),
        "in PAGI::Routing's :all");
    ok(!(grep { $_ eq 'endpoint' } @{ $PAGI::Routing::EXPORT_TAGS{routes} }),
        "not in PAGI::Routing's :routes");
    ok(!(grep { $_ eq 'endpoint' } @{ $PAGI::Tools::EXPORT_TAGS{routes} }),
        "not in PAGI::Tools' :routes");
};

done_testing;
