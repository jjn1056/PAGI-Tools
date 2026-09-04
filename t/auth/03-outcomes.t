use strict;
use warnings;

use Test2::V0;
use Future;
use JSON::MaybeXS qw(decode_json);
use Scalar::Util qw(refaddr);

use PAGI::Auth qw(challenge forbid basic bearer custom_challenge);
use PAGI::Auth::Outcomes;
use PAGI::Pages;
use PAGI::Utils qw(invoke_app);

sub http_scope {
    my (%args) = @_;
    my @headers = @{$args{headers} || []};
    if (exists $args{accept}) {
        my @accept = ref($args{accept}) eq 'ARRAY'
            ? @{$args{accept}} : ($args{accept});
        push @headers, map { ['Accept' => $_] } @accept;
    }
    return {
        type         => 'http',
        method       => 'GET',
        path         => '/',
        headers      => \@headers,
        http_version => '1.1',
        query_string => '',
    };
}

sub run_http_app {
    my ($application, %args) = @_;
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    Future->wrap(invoke_app(
        $application, http_scope(%args), sub { Future->done }, $send,
    ))->get;
    return \@events;
}

sub header_all {
    my ($start, $name) = @_;
    my $wanted = lc $name;
    return [map { $_->[1] }
        grep { lc($_->[0]) eq $wanted }
        @{$start->{headers} || []}];
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

{
    package Local::OutcomePages;
    our @ISA = ('PAGI::Pages');
    our @SEEN_POLICY;
    our @RESPONSES;

    sub new {
        my ($class, %args) = @_;
        my $marker = delete $args{marker};
        my $self = $class->SUPER::new(%args);
        $self->{marker} = $marker;
        return $self;
    }

    sub _response_for {
        my $self = shift;
        my $response = $self->SUPER::_response_for(@_);
        push @RESPONSES, $response;
        return $response;
    }

    sub render_problem {
        my ($self, $page) = @_;
        push @SEEN_POLICY, $self;
        return {
            policy_marker => $self->{marker},
            renderer_note => 'distinctive outcome renderer',
        };
    }
}

{
    package Local::OutcomePolicy;
    our @ISA = ('PAGI::Auth::Outcomes');
    our $NEW_COUNT = 0;

    sub new {
        my $class = shift;
        ++$NEW_COUNT;
        return $class->SUPER::new(@_);
    }
}

subtest 'challenge constructs a negotiated 401 application' => sub {
    my $failure = challenge(
        challenges => [
            basic(realm => 'Staff'),
            bearer(realm => 'api'),
        ],
        detail => 'Authenticate with either supported scheme.',
    );
    isa_ok $failure, 'PAGI::Pages::Application';

    my $events = run_http_app(
        $failure, accept => 'application/problem+json',
    );
    is $events->[0]{status}, 401;
    is header_all($events->[0], 'WWW-Authenticate'), [
        'Basic realm="Staff"',
        'Bearer realm="api"',
    ];
    is header_all($events->[0], 'Vary'), ['Accept'];
    is header_all($events->[0], 'Cache-Control'), ['no-store'];
    is decode_json(response_body($events))->{detail},
        'Authenticate with either supported scheme.';
};

subtest 'Pages owns representation negotiation and presentation options' => sub {
    my $failure = challenge(
        challenges  => basic(realm => 'Staff'),
        detail      => 'Present credentials.',
        type        => 'https://example.test/problems/authentication',
        title       => 'Authentication Required',
        instance    => '/requests/17',
        extensions  => { request_id => 'req-17' },
        headers     => ['X-Auth-Policy' => 'interactive'],
        cache_control => 'private, no-store',
    );

    my $html = run_http_app($failure, accept => 'text/html');
    is header_all($html->[0], 'Content-Type'), ['text/html; charset=utf-8'];
    like response_body($html), qr/Authentication Required/;

    my $text = run_http_app($failure, accept => 'text/plain');
    is header_all($text->[0], 'Content-Type'), ['text/plain; charset=utf-8'];
    like response_body($text), qr/Present credentials\./;

    my $problem = run_http_app(
        $failure, accept => 'application/problem+json',
    );
    is header_all($problem->[0], 'Content-Type'),
        ['application/problem+json'];
    is decode_json(response_body($problem)), {
        type       => 'https://example.test/problems/authentication',
        title      => 'Authentication Required',
        status     => 401,
        detail     => 'Present credentials.',
        instance   => '/requests/17',
        request_id => 'req-17',
    };
    is header_all($problem->[0], 'X-Auth-Policy'), ['interactive'];
    is header_all($problem->[0], 'Cache-Control'), ['private, no-store'];

    my $repeated = run_http_app(
        $failure,
        accept => ['text/html;q=0.1', 'text/plain;q=0.9'],
    );
    is header_all($repeated->[0], 'Content-Type'),
        ['text/plain; charset=utf-8'],
        'repeated Accept fields participate in negotiation';

    my $rejected = run_http_app(
        $failure,
        accept => 'text/html;q=0, text/plain;q=0, application/json;q=0, application/problem+json;q=0',
    );
    is header_all($rejected->[0], 'Content-Type'),
        ['text/html; charset=utf-8'],
        'total rejection falls back to the Pages default';

    my $fixed = challenge(
        challenges => basic(realm => 'Fixed'),
        as         => 'text',
    );
    my $fixed_events = run_http_app($fixed, accept => 'text/html');
    is header_all($fixed_events->[0], 'Content-Type'),
        ['text/plain; charset=utf-8'];
    is header_all($fixed_events->[0], 'Vary'), [],
        'a fixed representation does not vary on Accept';

    like dies {
        challenge(challenges => basic(realm => 'x'), as => 'xml')
    }, qr/PAGI::Pages as/, 'Pages diagnostics remain authoritative';
};

subtest 'forbid supports challenge-free and challenged 403 outcomes' => sub {
    my $plain = forbid(detail => 'Authenticated but not permitted.');
    isa_ok $plain, 'PAGI::Pages::Application';
    my $plain_events = run_http_app($plain, accept => 'text/plain');
    is $plain_events->[0]{status}, 403;
    is header_all($plain_events->[0], 'WWW-Authenticate'), [];

    my $challenged = forbid(
        challenges => [
            basic(realm => 'staff'),
            custom_challenge(scheme => 'StepUp', params => { level => 2 }),
        ],
        headers => ['X-Reason' => 'step-up-required'],
    );
    my $events = run_http_app($challenged, accept => 'text/plain');
    is $events->[0]{status}, 403;
    is header_all($events->[0], 'WWW-Authenticate'), [
        'Basic realm="staff"', 'StepUp level="2"',
    ], 'Auth-owned 403 challenges remain separate header lines';
    is header_all($events->[0], 'X-Reason'), ['step-up-required'];
};

subtest 'challenge collection validation rejects every invalid shape' => sub {
    isa_ok challenge(challenges => basic(realm => 'one')),
        'PAGI::Pages::Application';
    isa_ok challenge(challenges => [basic(realm => 'one')]),
        'PAGI::Pages::Application';

    my @cases = (
        ['missing challenges', sub { challenge() }, qr/challenges.*required/i],
        ['empty collection', sub { challenge(challenges => []) }, qr/challenges.*nonempty/i],
        ['undefined forbid collection', sub { forbid(challenges => undef) }, qr/challenges\[0\].*Challenge/i],
        ['raw string', sub { challenge(challenges => 'Basic realm="raw"') }, qr/challenges\[0\].*Challenge/i],
        ['unblessed hash', sub { challenge(challenges => {}) }, qr/challenges\[0\].*Challenge/i],
        ['nested array position', sub {
            challenge(challenges => [basic(realm => 'one'), [basic(realm => 'two')]])
        }, qr/challenges\[1\].*Challenge/i],
        ['arbitrary blessed position', sub {
            challenge(challenges => [basic(realm => 'one'), bless({}, 'Local::NotChallenge')])
        }, qr/challenges\[1\].*Challenge/i],
        ['forbid invalid position', sub {
            forbid(challenges => [basic(realm => 'one'), 'raw'])
        }, qr/challenges\[1\].*Challenge/i],
    );
    for my $case (@cases) {
        like dies { $case->[1]->() }, $case->[2], $case->[0];
    }
};

subtest 'Auth option and header ownership are closed' => sub {
    my @cases = (
        ['caller WWW-Authenticate', sub {
            forbid(headers => ['WWW-Authenticate' => 'Basic realm="raw"'])
        }, qr/WWW-Authenticate.*Auth-owned|Auth-owned.*WWW-Authenticate/i],
        ['case-insensitive caller WWW-Authenticate', sub {
            challenge(
                challenges => basic(realm => 'one'),
                headers => ['wWw-AuThEnTiCaTe' => 'Basic realm="raw"'],
            )
        }, qr/WWW-Authenticate.*Auth-owned|Auth-owned.*WWW-Authenticate/i],
        ['status option', sub {
            challenge(challenges => basic(realm => 'one'), status => 400)
        }, qr/unknown.*status/i],
        ['singular challenge option', sub {
            challenge(challenge => basic(realm => 'one'))
        }, qr/unknown.*challenge/i],
        ['proxy option', sub {
            challenge(
                challenges => basic(realm => 'one'),
                proxy_challenges => [basic(realm => 'proxy')],
            )
        }, qr/unknown.*proxy_challenges/i],
        ['unknown option', sub {
            forbid(redirect_to => '/login')
        }, qr/unknown.*redirect_to/i],
    );
    for my $case (@cases) {
        like dies { $case->[1]->() }, $case->[2], $case->[0];
    }

    like dies {
        forbid(
            challenges => [basic(realm => 'one')],
            headers => {},
        )
    }, qr/PAGI::Pages headers must be an even-length arrayref/,
        'Pages validates caller headers before Auth appends owned fields';
};

subtest 'known Bearer errors enforce the complete outcome matrix' => sub {
    my @challenge_valid = (
        ['absent error', bearer(realm => 'api')],
        ['invalid_token', bearer(error => 'invalid_token')],
        ['insufficient_user_authentication',
            bearer(error => 'insufficient_user_authentication')],
    );
    for my $case (@challenge_valid) {
        my $events = run_http_app(
            challenge(challenges => $case->[1], as => 'text'),
        );
        is $events->[0]{status}, 401, "challenge accepts $case->[0]";
    }

    like dies {
        challenge(challenges => bearer(error => 'invalid_request'))
    }, qr/\APAGI::Auth challenge cannot use Bearer invalid_request; use an explicit 400 at /,
        'invalid_request directs callers to an explicit 400';
    like dies {
        challenge(challenges => bearer(error => 'insufficient_scope'))
    }, qr/\APAGI::Auth challenge cannot use Bearer insufficient_scope; use forbid at /,
        'insufficient_scope directs callers to forbid';

    my $scope_events = run_http_app(forbid(
        challenges => bearer(error => 'insufficient_scope'),
        as => 'text',
    ));
    is $scope_events->[0]{status}, 403,
        'forbid accepts insufficient_scope';

    my @forbid_invalid = (
        ['absent error', bearer(realm => 'api')],
        ['invalid_token', bearer(error => 'invalid_token')],
        ['invalid_request', bearer(error => 'invalid_request')],
        ['insufficient_user_authentication',
            bearer(error => 'insufficient_user_authentication')],
    );
    for my $case (@forbid_invalid) {
        like dies { forbid(challenges => $case->[1]) },
            qr/\APAGI::Auth forbid Bearer challenge requires error=insufficient_scope at /,
            "forbid rejects $case->[0]";
    }

    for my $factory (
        [challenge => sub { challenge(@_) }, 401],
        [forbid    => sub { forbid(@_) },    403],
    ) {
        my ($name, $make, $status) = @$factory;
        my $events = run_http_app($make->(
            challenges => bearer(error => 'extension_error'),
            as => 'text',
        ));
        is $events->[0]{status}, $status,
            "$name accepts unknown Bearer extension errors without inference";
    }
};

subtest 'configured policies retain identity and remain reusable' => sub {
    local @Local::OutcomePages::SEEN_POLICY;
    local @Local::OutcomePages::RESPONSES;

    my $pages = Local::OutcomePages->new(
        as => 'auto', marker => 'retained-instance',
    );
    my $outcomes = PAGI::Auth::Outcomes->new(pages => $pages);
    my $application = $outcomes->challenge(
        challenges => basic(realm => 'configured'),
    );

    my $problem = run_http_app(
        $application, accept => 'application/problem+json',
    );
    is decode_json(response_body($problem))->{policy_marker},
        'retained-instance';
    is refaddr($Local::OutcomePages::SEEN_POLICY[0]), refaddr($pages),
        'the exact configured Pages instance renders the outcome';

    run_http_app($application, accept => 'text/html');
    run_http_app($application, accept => 'text/plain');
    isnt refaddr($Local::OutcomePages::RESPONSES[-2]),
        refaddr($Local::OutcomePages::RESPONSES[-1]),
        'every invocation constructs a fresh concrete Response';

    my $app = $application->to_app;
    my (@html_events, @text_events);
    my $html_gate = Future->new;
    my $text_gate = Future->new;
    my $html_calls = 0;
    my $text_calls = 0;
    my $html_future = Future->wrap($app->(
        http_scope(accept => 'text/html'),
        sub { Future->done },
        sub {
            push @html_events, $_[0];
            return ++$html_calls == 1 ? $html_gate : Future->done;
        },
    ));
    my $text_future = Future->wrap($app->(
        http_scope(accept => 'text/plain'),
        sub { Future->done },
        sub {
            push @text_events, $_[0];
            return ++$text_calls == 1 ? $text_gate : Future->done;
        },
    ));
    ok !$html_future->is_ready && !$text_future->is_ready,
        'one outcome application serves overlapping requests';
    $text_gate->done;
    $text_future->get;
    ok !$html_future->is_ready,
        'completing one request does not release the other';
    $html_gate->done;
    $html_future->get;
    is header_all($html_events[0], 'Content-Type'),
        ['text/html; charset=utf-8'];
    is header_all($text_events[0], 'Content-Type'),
        ['text/plain; charset=utf-8'];
    isnt refaddr($Local::OutcomePages::RESPONSES[-2]),
        refaddr($Local::OutcomePages::RESPONSES[-1]),
        'overlapping requests retain distinct concrete Responses';
};

subtest 'class, instance, subclass, and constructor contracts are explicit' => sub {
    my $class_application = PAGI::Auth::Outcomes->challenge(
        challenges => basic(realm => 'class'),
    );
    isa_ok $class_application, 'PAGI::Pages::Application';

    my $instance = PAGI::Auth::Outcomes->new;
    isa_ok $instance->forbid, 'PAGI::Pages::Application';

    local $Local::OutcomePolicy::NEW_COUNT = 0;
    my $subclass_application = Local::OutcomePolicy->challenge(
        challenges => basic(realm => 'subclass'),
    );
    isa_ok $subclass_application, 'PAGI::Pages::Application';
    is $Local::OutcomePolicy::NEW_COUNT, 1,
        'subclass class invocation constructs the subclass policy once';

    my @bad = (
        ['unknown key', sub { PAGI::Auth::Outcomes->new(mode => 'strict') }, qr/unknown option 'mode'/],
        ['non-Pages object', sub { PAGI::Auth::Outcomes->new(pages => bless({}, 'Local::NotPages')) }, qr/pages must be a PAGI::Pages instance/],
        ['Pages class name', sub { PAGI::Auth::Outcomes->new(pages => 'PAGI::Pages') }, qr/pages must be a PAGI::Pages instance/],
        ['unblessed hashref', sub { PAGI::Auth::Outcomes->new(pages => {}) }, qr/pages must be a PAGI::Pages instance/],
        ['unblessed arrayref', sub { PAGI::Auth::Outcomes->new(pages => []) }, qr/pages must be a PAGI::Pages instance/],
    );
    for my $case (@bad) {
        like dies { $case->[1]->() }, $case->[2], $case->[0];
    }

    ok !PAGI::Auth->can('new'), 'PAGI::Auth has no constructor';
};

done_testing;
