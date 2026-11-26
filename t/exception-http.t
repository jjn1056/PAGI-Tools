use v5.24;
use warnings;
use Test2::V0;
use Future;

use PAGI::Exception::HTTP;

package Local::Cause {
    use overload '""' => sub { 'a cause object' }, fallback => 1;
    sub new { bless {}, shift }
}

subtest 'new: the fields given, and the defaults' => sub {
    my $error = PAGI::Exception::HTTP->new(status_code => 409, client_message => 'That name is taken.');
    is $error->status_code, 409, 'status_code';
    is $error->client_message, 'That name is taken.', 'client_message';
    is $error->headers, [], 'no headers: an empty list';
    is $error->cause, undef, 'no cause';

    my $full = PAGI::Exception::HTTP->new(status_code => 503, headers => [['retry-after', '30']], cause => 'db down');
    is $full->headers, [['retry-after', '30']], 'headers';
    is $full->cause, 'db down', 'cause';
    is $full->client_message, undef, 'no client_message';
};

subtest 'throw dies with the object' => sub {
    my $error = dies { PAGI::Exception::HTTP->throw(status_code => 404, client_message => 'No note 9.') };
    isa_ok $error, 'PAGI::Exception::HTTP';
    is [$error->status_code, $error->client_message], [404, 'No note 9.'], 'with the fields given';
};

subtest 'what new refuses' => sub {
    like dies { PAGI::Exception::HTTP->new }, qr/\Astatus_code is required: an HTTP error status from 400 to 599/,
        'no status_code';
    like dies { PAGI::Exception::HTTP->new(client_message => 'x') }, qr/\Astatus_code is required/,
        'a message but no status_code';
    for my $status (399, 600, '4xx', 404.5, '') {
        like dies { PAGI::Exception::HTTP->new(status_code => $status) },
            qr/\Astatus_code must be an integer from 400 to 599/, "status_code '$status'";
    }
    like dies { PAGI::Exception::HTTP->new(status_code => 404, colour => 'red') }, qr/\Aunknown argument: colour/,
        'an unknown argument';
    like dies { PAGI::Exception::HTTP->throw(status_code => 200) }, qr/\Astatus_code must be an integer from 400 to 599/,
        'throw checks the same way';
};

subtest 'headers is a copy each time' => sub {
    my $error = PAGI::Exception::HTTP->new(status_code => 503, headers => [['retry-after', '30']]);
    my $headers = $error->headers;
    push @$headers, ['x-more', '1'];
    $headers->[0][1] = '99';
    is $error->headers, [['retry-after', '30']], 'changing the list returned changes nothing';

    my @given = (['retry-after', '30']);
    my $kept = PAGI::Exception::HTTP->new(status_code => 503, headers => \@given);
    push @given, ['x-more', '1'];
    $given[0][1] = '99';
    is $kept->headers, [['retry-after', '30']], 'changing the list given after new changes nothing';
};

subtest 'stringification: status, message or reason phrase, then the cause' => sub {
    is "" . PAGI::Exception::HTTP->new(status_code => 404), '404 Not Found', 'no message: the reason phrase';
    is "" . PAGI::Exception::HTTP->new(status_code => 409, client_message => 'That name is taken.'),
        '409 That name is taken.', 'the message';
    is "" . PAGI::Exception::HTTP->new(status_code => 503, cause => 'database: connection refused'),
        '503 Service Unavailable (cause: database: connection refused)', 'a cause';
    is "" . PAGI::Exception::HTTP->new(status_code => 500, cause => "boom at x.pl line 3.\n"),
        '500 Internal Server Error (cause: boom at x.pl line 3.)', "a cause's trailing newline is left out";
    is "" . PAGI::Exception::HTTP->new(status_code => 502, cause => Local::Cause->new),
        '502 Bad Gateway (cause: a cause object)', 'an object cause: its string';
};

subtest 'true, so it can fail a Future' => sub {
    my $error = PAGI::Exception::HTTP->new(status_code => 404);
    ok !!$error, 'true in boolean context';
    my $future = Future->fail($error);
    ok $future->is_failed, 'a failed Future';
    is(($future->failure)[0], exact_ref($error), 'whose failure is the same object');
};

subtest 'reason phrases, as the string shows them' => sub {
    my %phrase = (400 => 'Bad Request', 404 => 'Not Found', 418 => "I'm a teapot", 429 => 'Too Many Requests',
        451 => 'Unavailable For Legal Reasons', 500 => 'Internal Server Error', 503 => 'Service Unavailable',
        599 => 'Error');
    is "" . PAGI::Exception::HTTP->new(status_code => $_), "$_ $phrase{$_}", "$_" for sort keys %phrase;
};

package Local::BadCause {
    use overload '""' => sub { die "cause string died\n" }, fallback => 1;
    sub new { bless {}, shift }
}

subtest 'true even when its cause cannot be a string' => sub {
    my $error = PAGI::Exception::HTTP->new(status_code => 503, cause => Local::BadCause->new);
    ok lives { ok !!$error, 'true' }, 'without asking the cause for its string';
    my $future = Future->fail($error);
    is(($future->failure)[0], exact_ref($error), 'so it can fail a Future');
};

done_testing;
