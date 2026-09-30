use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use PAGI::Auth qw(auth auth_result unauth_result);
use PAGI::Auth::SimpleUser;
use PAGI::Middleware::Authentication;
use PAGI::Response;

{
    package Local::AuthBackend;

    sub new {
        my ($class, $returned) = @_;
        return bless { returned => $returned, calls => 0, argc => undef }, $class;
    }

    sub authenticate {
        my ($self, @args) = @_;
        ++$self->{calls};
        $self->{argc} = scalar(@_);
        return ref($self->{returned}) eq 'CODE'
            ? $self->{returned}->(@args)
            : $self->{returned};
    }
}

sub invocation {
    my ($middleware, $scope, $app) = @_;
    my $receive = sub { die 'unexpected body read' };
    my $send = sub { die 'unexpected response' };
    $app ||= sub { Future->done };
    return $middleware->wrap($app)->($scope, $receive, $send);
}

subtest 'construction is lazy and invocation installs a child-scope result' => sub {
    my ($calls, $seen) = (0, undef);
    my $outer = { type => 'http', headers => [], path => '/' };
    my $receive = sub { die 'unexpected body read' };
    my $send = sub { die 'unexpected response' };
    my $mw = PAGI::Middleware::Authentication->new(backend => sub {
        my ($request) = @_;
        ++$calls;
        is scalar(@_), 1, 'callback receives exactly one argument';
        is refaddr($request->scope), refaddr($outer), 'request retains outer scope';
        return unauth_result();
    });
    my $app = $mw->wrap(sub {
        my ($scope, $recv, $snd) = @_;
        $seen = auth($scope);
        isnt refaddr($scope), refaddr($outer), 'downstream receives a child scope';
        is refaddr($recv), refaddr($receive), 'receive is preserved';
        is refaddr($snd), refaddr($send), 'send is preserved';
        return Future->done;
    });
    is $calls, 0, 'construction does not authenticate';
    $app->($outer, $receive, $send)->get;
    is $calls, 1, 'backend runs once per invocation';
    ok !$seen->user->is_authenticated, 'guest result continues downstream';
    ok !exists $outer->{'pagi.auth'}, 'outer scope is unchanged';
};

subtest 'authenticated, guest, and rejected results all continue' => sub {
    my $user = PAGI::Auth::SimpleUser->new(identity => 'alice');
    my @cases = (
        ['authenticated', auth_result(user => $user, scopes => ['read']), 1, undef],
        ['guest', unauth_result(), 0, undef],
        ['rejected', unauth_result(failure => { message => 'No access', code => 'bad_token' }), 0, 'bad_token'],
    );
    for my $case (@cases) {
        my ($name, $result, $authenticated, $failure_code) = @$case;
        my $seen;
        my ($future) = invocation(
            PAGI::Middleware::Authentication->new(backend => sub { $result }),
            { type => 'http', headers => [] },
            sub { $seen = auth($_[0]); return Future->done },
        );
        $future->get;
        is !!$seen->user->is_authenticated, !!$authenticated, "$name user state continues";
        is $seen->failure ? $seen->failure->code : undef, $failure_code,
            "$name failure state continues";
    }
};

subtest 'Future-backed authenticated and rejected results continue' => sub {
    my $user = PAGI::Auth::SimpleUser->new(identity => 'future-user');
    my @results = (
        auth_result(user => $user),
        unauth_result(failure => { message => 'Rejected later', code => 'future_rejection' }),
    );
    for my $expected (@results) {
        my $seen;
        invocation(
            PAGI::Middleware::Authentication->new(
                backend => sub { Future->done($expected) },
            ),
            { type => 'http', headers => [] },
            sub { $seen = auth($_[0]); return Future->done },
        )->get;
        is refaddr($seen), refaddr($expected), 'Future result reaches downstream';
    }
};

subtest 'closure backend is reused without retaining invocation results' => sub {
    my $calls = 0;
    my $backend = sub { ++$calls; return unauth_result() };
    my $middleware = PAGI::Middleware::Authentication->new(backend => $backend);
    invocation($middleware, { type => 'http', headers => [] })->get for 1 .. 2;
    is $calls, 2, 'same closure serves multiple invocations';
};

subtest 'object backend receives self plus one Request and is reused' => sub {
    my $backend = Local::AuthBackend->new(unauth_result());
    my $middleware = PAGI::Middleware::Authentication->new(backend => $backend);
    invocation($middleware, { type => 'http', headers => [] })->get;
    invocation($middleware, { type => 'websocket', headers => [] })->get;
    is $backend->{calls}, 2, 'same object serves multiple invocations';
    is $backend->{argc}, 2, 'object method receives self plus one Request';
};

subtest 'pending backend and downstream Futures remain attached' => sub {
    my $backend_gate = Future->new;
    my $downstream_gate = Future->new;
    my $downstream_calls = 0;
    my $middleware = PAGI::Middleware::Authentication->new(
        backend => sub { $backend_gate },
    );
    my ($running) = invocation($middleware, { type => 'sse', headers => [] }, sub {
        ++$downstream_calls;
        return $downstream_gate;
    });
    ok !$running->is_ready, 'invocation waits for backend';
    is $downstream_calls, 0, 'downstream waits for authentication';
    $backend_gate->done(unauth_result());
    is $downstream_calls, 1, 'downstream starts after backend settles';
    ok !$running->is_ready, 'invocation waits for downstream';
    $downstream_gate->done;
    $running->get;
    ok !$backend_gate->is_cancelled, 'backend Future is not cancelled';
    ok !$downstream_gate->is_cancelled, 'downstream Future is not cancelled';
};

subtest 'backend and downstream failures propagate unchanged' => sub {
    my $sync = PAGI::Middleware::Authentication->new(backend => sub { die "sync failure\n" });
    like dies { invocation($sync, { type => 'http', headers => [] })->get }, qr/sync failure/,
        'synchronous backend exception propagates';

    my $async = PAGI::Middleware::Authentication->new(
        backend => sub { Future->fail('backend failure') },
    );
    like dies { invocation($async, { type => 'http', headers => [] })->get }, qr/backend failure/,
        'failed backend Future propagates';

    my $downstream = PAGI::Middleware::Authentication->new(backend => sub { unauth_result() });
    like(dies {
        invocation($downstream, { type => 'http', headers => [] },
            sub { Future->fail('downstream failure') })->get
    }, qr/downstream failure/, 'failed downstream Future propagates');
};

subtest 'invalid backend returns are rejected before downstream' => sub {
    my @cases = (
        ['undef', undef],
        ['bare user', PAGI::Auth::SimpleUser->new(identity => 'alice')],
        ['hash', {}],
        ['response', PAGI::Response->new('', status => 401)],
    );
    for my $case (@cases) {
        my ($name, $returned) = @$case;
        my $called = 0;
        my $middleware = PAGI::Middleware::Authentication->new(
            backend => sub { $returned },
        );
        like(dies {
            invocation($middleware, { type => 'http', headers => [] },
                sub { ++$called; Future->done })->get
        }, qr/PAGI::Auth::Result/, "$name is not a result");
        is $called, 0, "$name does not reach downstream";
    }

    my $multi = PAGI::Middleware::Authentication->new(
        backend => sub { Future->done(unauth_result(), unauth_result()) },
    );
    like dies { invocation($multi, { type => 'http', headers => [] })->get },
        qr/must return one Auth result/, 'multi-value Future completion is rejected';
};

subtest 'headers are backend policy and diagnostics do not retain credentials' => sub {
    my @seen;
    my $middleware = PAGI::Middleware::Authentication->new(backend => sub {
        my ($request) = @_;
        push @seen, $request->header('authorization');
        return unauth_result(failure => { message => 'Credentials were not accepted' });
    });
    for my $headers ([], [['authorization', 'Digest raw-secret']]) {
        my $installed;
        my ($future) = invocation($middleware, { type => 'http', headers => $headers }, sub {
            $installed = auth($_[0]);
            return Future->done;
        });
        $future->get;
        unlike $installed->failure->message, qr/raw-secret/, 'failure has no raw credential';
    }
    is \@seen, [undef, 'Digest raw-secret'], 'backend receives absent and unsupported schemes';
};

subtest 'unsupported scopes pass through unchanged before Request construction' => sub {
    my $calls = 0;
    my $outer = { type => 'lifespan' };
    my ($seen_scope, $seen_receive, $seen_send);
    my $receive = sub { Future->done({ type => 'lifespan.startup' }) };
    my $send = sub { Future->done };
    my $middleware = PAGI::Middleware::Authentication->new(
        backend => sub { ++$calls; die 'must not run' },
    );
    $middleware->wrap(sub {
        ($seen_scope, $seen_receive, $seen_send) = @_;
        return Future->done;
    })->($outer, $receive, $send)->get;
    is $calls, 0, 'backend is not called';
    is refaddr($seen_scope), refaddr($outer), 'scope identity is preserved';
    is refaddr($seen_receive), refaddr($receive), 'receive identity is preserved';
    is refaddr($seen_send), refaddr($send), 'send identity is preserved';
};

subtest 'constructor accepts only one valid backend option' => sub {
    my $object = Local::AuthBackend->new(unauth_result());
    ok lives { PAGI::Middleware::Authentication->new(backend => sub { unauth_result() }) },
        'coderef is accepted';
    ok lives { PAGI::Middleware::Authentication->new(backend => $object) },
        'authenticate object is accepted';

    my @invalid = (
        ['missing backend', sub { PAGI::Middleware::Authentication->new }],
        ['undefined backend', sub { PAGI::Middleware::Authentication->new(backend => undef) }],
        ['string backend', sub { PAGI::Middleware::Authentication->new(backend => 'Local::AuthBackend') }],
        ['constructor hash', sub { PAGI::Middleware::Authentication->new(backend => { class => 'Local::AuthBackend' }) }],
        ['object without authenticate', sub { PAGI::Middleware::Authentication->new(backend => bless({}, 'Local::NoAuthenticate')) }],
        ['unknown callback option', sub { PAGI::Middleware::Authentication->new(backend => sub { unauth_result() }, callback => sub {}) }],
        ['unknown parser option', sub { PAGI::Middleware::Authentication->new(backend => sub { unauth_result() }, parser => sub {}) }],
    );
    for my $case (@invalid) {
        like dies { $case->[1]->() }, qr/backend|unknown|option/i, $case->[0];
    }
};

subtest 'cancellation follows the pending backend or downstream operation' => sub {
    for my $phase (qw(backend downstream)) {
        my $pending = Future->new;
        my ($calls, $responses, $cancelled) = (0, 0, 0);
        $pending->on_cancel(sub { ++$cancelled });
        my $middleware = PAGI::Middleware::Authentication->new(backend => sub {
            return $phase eq 'backend' ? $pending : unauth_result();
        });
        my $app = $middleware->wrap(async sub {
            ++$calls;
            await $pending;
            ++$responses;
        });
        my $running = $app->({ type => 'http', headers => [] },
            sub { die 'unexpected receive' }, sub { die 'unexpected send' });
        ok !$running->is_ready, "$phase is pending";
        $running->cancel;
        ok $pending->is_cancelled, "$phase operation receives cancellation";
        is $cancelled, 1, "$phase cancellation happens once";
        is $calls, $phase eq 'backend' ? 0 : 1, "$phase downstream call count";
        # A late producer completion must not resume the cancelled invocation.
        $pending->done(unauth_result());
        is $responses, 0, "$phase has no late response";
        ok $running->is_cancelled, "$phase invocation remains cancelled";
    }
};

subtest 'a pending backend failure stays operational and never installs a guest' => sub {
    my $pending = Future->new;
    my $called = 0;
    my $middleware = PAGI::Middleware::Authentication->new(backend => sub { $pending });
    my $running = invocation($middleware, { type => 'http', headers => [] }, sub {
        ++$called;
        return Future->done;
    });
    $pending->fail('database unavailable', 'storage', 'lookup');
    is [$running->failure], ['database unavailable', 'storage', 'lookup'],
        'failure category and details propagate unchanged';
    is $called, 0, 'operational failure never reaches a guest handler';
};

subtest 'one middleware keeps reverse-order pending invocations isolated' => sub {
    my %pending = map { $_ => Future->new } qw(first second);
    my (@seen, @running);
    my $middleware = PAGI::Middleware::Authentication->new(backend => sub {
        return $pending{$_[0]->header('x-request')};
    });
    my $app = $middleware->wrap(sub {
        my ($scope) = @_;
        my $context = auth($scope);
        push @seen, [
            $context->user->identity,
            [@{$context->credentials->scopes}],
            $context->failure ? $context->failure->code : undef,
        ];
        return Future->done;
    });
    for my $name (qw(first second)) {
        push @running, $app->({ type => 'http', headers => [['x-request', $name]] },
            sub { die 'unexpected receive' }, sub { die 'unexpected send' });
    }
    is \@seen, [], 'both backends are pending';
    $pending{second}->done(unauth_result(scopes => ['preview'],
        failure => { message => 'Rejected second', code => 'second_rejected' }));
    ok !$running[0]->is_ready, 'first invocation remains pending';
    $pending{first}->done(auth_result(
        user => PAGI::Auth::SimpleUser->new(identity => 'first'), scopes => ['private']));
    $_->get for @running;
    is \@seen, [
        ['', ['preview'], 'second_rejected'],
        ['first', ['private'], undef],
    ], 'user, grants, and failure belong to their own completion';
};

done_testing;
