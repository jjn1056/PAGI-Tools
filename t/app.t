use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempdir);
use Future;
use Future::AsyncAwait;
use lib 'lib';
use PAGI::App;
use PAGI::Test::Client;
use PAGI::Tools qw(compose response route);

package Local::Native {
    use parent -norequire, 'PAGI::App';
    use Future::AsyncAwait;
    our $PREPARED = 0;
    sub prepare_app { $PREPARED++ }
    async sub call {
        my ($self, $scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => "hello $self->{name}", more => 0 });
    }
}
package Local::Composed {
    use parent -norequire, 'PAGI::App';
    use PAGI::Tools qw(compose response route);
    sub to_app { compose(routes => [route('/' => sub { response('Text', 'composed') })])->to_app }
}
package Local::Empty { use parent -norequire, 'PAGI::App' }
package main;

subtest 'new takes a list or a hashref' => sub {
    is { %{ Local::Native->new(name => 'a') } }, { name => 'a' }, 'a list';
    is { %{ Local::Native->new({ name => 'b' }) } }, { name => 'b' }, 'a hashref';
};

subtest 'to_app runs prepare_app and returns a coderef calling call' => sub {
    $Local::Native::PREPARED = 0;
    my $app = Local::Native->new(name => 'x');
    my $code = $app->to_app;
    is ref($code), 'CODE', 'a coderef';
    is $Local::Native::PREPARED, 1, 'prepare_app ran once';
    is(PAGI::Test::Client->new(app => $code)->get('/')->text, 'hello x', 'it calls call');
    $app->to_app;
    is $Local::Native::PREPARED, 2, 'and again for each to_app';
};

subtest 'overriding to_app replaces the whole application' => sub {
    is(PAGI::Test::Client->new(app => Local::Composed->new)->get('/')->text, 'composed');
};

subtest 'neither call nor to_app' => sub {
    my $code = Local::Empty->new->to_app;
    like dies { $code->({ type => 'http' }, sub {}, sub {}) },
        qr/\ALocal::Empty must implement call or override to_app/, 'calling it dies';
};

SKIP: {
    skip 'Moo is not installed', 1 unless eval { require Moo; 1 };
    subtest 'a Moo subclass' => sub {
        eval q{
            package Local::MooApp;
            use Moo;
            extends 'PAGI::App';
            has name => (is => 'ro', default => 'moo');
            sub call { my ($self, $s, $r, $send) = @_;
                $send->({ type => 'http.response.start', status => 200, headers => [] })->then(sub {
                    $send->({ type => 'http.response.body', body => $self->name, more => 0 }) }) }
            1;
        } or die $@;
        is Local::MooApp->new->name, 'moo', 'default';
        is Local::MooApp->new({ name => 'h' })->name, 'h', 'a hashref';
        is(PAGI::Test::Client->new(app => Local::MooApp->new(name => 'l'))->get('/')->text, 'l', 'answers');
    };
}

SKIP: {
    skip 'Moose is not installed', 1 unless eval { require Moose; 1 };
    subtest 'a Moose subclass without MooseX::NonMoose is refused at new' => sub {
        eval q{ package Local::MooseApp; use Moose; extends 'PAGI::App'; 1 } or die $@;
        like dies { Local::MooseApp->new },
            qr/\APAGI::App subclass Local::MooseApp is a Moose class whose new is not Moose's/, 'loud';
    };
}

# A module file whose new counts constructions, loaded the ways a server
# and a test load it.
my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/Local";
open my $fh, '>', "$dir/Local/Modulino.pm" or die $!;
print {$fh} <<'PERL';
package Local::Modulino;
use strict;
use warnings;
use parent 'PAGI::App';
our $BUILT = 0;
sub new { $BUILT++; shift->SUPER::new(@_) }
sub to_app { require PAGI::Tools; PAGI::Tools::compose(routes => [PAGI::Tools::route('/' => sub { PAGI::Tools::response('Text', 'modulino') })])->to_app }
__PACKAGE__->run_if_script;
PERL
close $fh;

subtest 'loaded by path, as pagi-server --app does: builds nothing until to_app' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $provider = do "$dir/Local/Modulino.pm";
    die $@ if $@;
    ok $provider->can('to_app') && !$provider->isa('Local::Modulino'), 'a provider, not the class';
    is $Local::Modulino::BUILT, 0, 'loading built nothing';
    is $INC{'Local/Modulino.pm'}, "$dir/Local/Modulino.pm", 'recorded under its module name';
    my $code = $provider->to_app;
    is $Local::Modulino::BUILT, 1, 'to_app built it once';
    is(PAGI::Test::Client->new(app => $code)->get('/')->text, 'modulino', 'and it answers');
    unshift @INC, $dir;
    require Local::Modulino;
    shift @INC;
    is \@warnings, [], 'a later require compiled nothing again';
};

package Local::Echo {
    use parent -norequire, 'PAGI::App';
    use PAGI::Tools qw(compose response route);
    our $STARTED = 0;
    sub to_app {
        compose(
            routes => [
                route('/echo' => sub {
                    my ($r) = @_;
                    response('JSON', { method => $r->method, query => $r->query_string,
                        x => scalar $r->header('X-Thing'), auth => scalar $r->header('Authorization') });
                }, methods => [qw(GET POST PUT)]),
                route('/raw' => sub { my ($r) = @_; $r->body->then(sub { response('Text', "raw:$_[0]") }) },
                    methods => ['POST']),
                route('/cookies' => sub {
                    response('Text', 'c', headers => ['Set-Cookie' => 'a=1', 'Set-Cookie' => 'b=2']) }),
                route('/die' => sub { die "handler broke\n" }),
            ],
            lifespan => { startup => sub { $STARTED++ } },
        )->to_app;
    }
}
package main;

# Run run() with STDOUT and STDERR captured.
sub run_cli {
    my ($app, @args) = @_;
    my ($out, $err) = ('', '');
    open my $o, '>', \$out or die; open my $e, '>', \$err or die;
    my $status = do { local *STDOUT = $o; local *STDERR = $e; $app->run(@args) };
    return ($status, $out, $err);
}

subtest 'the grammar' => sub {
    my $app = Local::Echo->new;
    is [(PAGI::App::_parse_request('/echo'))[0, 1]], ['GET', '/echo'], 'the method defaults to GET';
    my ($m, $p, %o) = PAGI::App::_parse_request(GET => '/echo?a=1', 'X-Thing:', 'v', 'b=2 3');
    is [$m, $p, $o{headers}], ['GET', '/echo?a=1&b=2%203', [['X-Thing', 'v']]], 'a header; a field joins the query';
    (undef, undef, %o) = PAGI::App::_parse_request(POST => '/echo', 'b=2 3');
    is [$o{body}, $o{headers}], ['b=2%203', [['Content-Type', 'application/x-www-form-urlencoded']]],
        'a field is a urlencoded body for POST';
    (undef, undef, %o) = PAGI::App::_parse_request(POST => '/raw', 'Content:', 'hi');
    is $o{body}, 'hi', 'Content: is the body';
    (undef, $p, %o) = PAGI::App::_parse_request('ann:pw@/echo');
    is [$p, $o{headers}[0]], ['/echo', ['Authorization', 'Basic YW5uOnB3']], 'user:pass@';
    like dies { PAGI::App::_parse_request('FOO', '/x') }, qr/not a method or a path: 'FOO'/, 'unknown method';
    like dies { PAGI::App::_parse_request('GET') }, qr/a path is required/, 'a method with no path';
    like dies { PAGI::App::_parse_request(POST => '/x', 'Content:', 'a', 'b=1') }, qr/cannot be combined/, 'Content: with fields';
    (undef, $p) = PAGI::App::_parse_request("/caf\xC3\xA9?q=\xC3\xA9");
    is $p, '/caf%C3%A9?q=%C3%A9', 'non-ASCII path bytes are percent-encoded, not encoded twice';
};

subtest 'a field is bytes, as the command line gives it, and sent once encoded' => sub {
    my (undef, $out) = run_cli(Local::Echo->new, POST => '/raw', "t=caf\xC3\xA9");
    is $out, 'raw:t=caf%C3%A9', 'a POST field: UTF-8 bytes percent-encoded, not encoded twice';
    (undef, $out) = run_cli(Local::Echo->new, GET => '/echo', "t=caf\xC3\xA9");
    like $out, qr/"query":"t=caf%C3%A9"/, 'a GET field, the same';
};

subtest 'run prints the response and returns the exit status' => sub {
    $Local::Echo::STARTED = 0;
    my ($status, $out, $err) = run_cli(Local::Echo->new, GET => '/echo', 'X-Thing:', 'v');
    is $status, 0, 'exit 0';
    like $out, qr/"x":"v"/, 'the body on STDOUT';
    like $err, qr{\AHTTP/1\.1 200\n.*content-type: application/json}si, 'status and headers on STDERR';
    is $Local::Echo::STARTED, 1, 'lifespan startup ran';

    (undef, undef, $err) = run_cli(Local::Echo->new, '/cookies');
    is [$err =~ /^Set-Cookie: (\S+)$/mg], ['a=1', 'b=2'], 'a repeated header once per value';

    ($status) = run_cli(Local::Echo->new, '/nowhere');
    is $status, 1, 'a 404 exits 1';

    ($status, undef, $err) = run_cli(Local::Echo->new, '/die');
    is $status, 1, 'a dying handler exits 1';
    like $err, qr/handler broke/, 'and its exception is printed';

    ($status, undef, $err) = run_cli(Local::Echo->new);
    is [$status, $err =~ /\AUsage:/ ? 1 : 0], [2, 1], 'no arguments: usage on STDERR, exit 2';
    ($status, $out) = run_cli(Local::Echo->new, '--help');
    is [$status, $out =~ /\AUsage:/ ? 1 : 0], [0, 1], '--help: usage on STDOUT, exit 0';
    ($status, undef, $err) = run_cli(Local::Echo->new, 'FOO', '/x');
    is [$status, $err =~ /not a method or a path/ ? 1 : 0], [2, 1], 'a usage error exits 2';
};

subtest 'a failed startup exits 1' => sub {
    package Local::BadStart {
        use parent -norequire, 'PAGI::App';
        sub to_app { PAGI::Tools::compose(routes => [], lifespan => { startup => sub { die "no db\n" } })->to_app }
    }
    my ($status, undef, $err) = run_cli(Local::BadStart->new, '/');
    is $status, 1, 'exit 1';
    like $err, qr/no db/, 'the error is printed';
};

subtest 'a classic application that declines lifespan runs, as a server runs it' => sub {
    my ($status, $out, $err) = run_cli(Local::Native->new(name => 'cli'), '/');
    is $status, 0, 'exit 0' or diag $err;
    is $out, 'hello cli', 'the body on STDOUT';
};

subtest 'a classic application that sends lifespan.startup.failed exits 1' => sub {
    package Local::NativeBadStart {
        use parent -norequire, 'PAGI::App';
        use Future::AsyncAwait;
        async sub call {
            my ($self, $scope, $receive, $send) = @_;
            await $receive->();
            await $send->({ type => 'lifespan.startup.failed', message => "no db\n" });
        }
    }
    my ($status, undef, $err) = run_cli(Local::NativeBadStart->new, '/');
    is $status, 1, 'exit 1';
    like $err, qr/no db/, 'the message is printed';
};

subtest "a subclass's own _request, _parse_request, _usage and _escape do not reach the command line" => sub {
    package Local::OwnHelpers {
        use parent -norequire, 'Local::Composed';
        sub _request       { 'my own helper' }
        sub _parse_request { 'my own parser' }
        sub _usage         { 'my own usage' }
        sub _escape        { 'my own escape' }
    }
    my ($status, $out, $err) = run_cli(Local::OwnHelpers->new, GET => '/', 'a=b c');
    is [$status, $out], [0, 'composed'], 'run answers the request' or diag $err;
    ($status, undef, $err) = run_cli(Local::OwnHelpers->new);
    like $err, qr/\AUsage: /, "and prints PAGI::App's usage";
};

subtest 'run as a script: the exit status reaches the shell' => sub {
    my $script = "$dir/Local/Modulino.pm";
    my $out = `$^X -Ilib -I$dir $script GET / 2>/dev/null`;
    is [$? >> 8, $out], [0, 'modulino'], 'GET /';
    `$^X -Ilib -I$dir $script /missing 2>/dev/null`;
    is $? >> 8, 1, 'a 404 exits 1';
};

done_testing;
