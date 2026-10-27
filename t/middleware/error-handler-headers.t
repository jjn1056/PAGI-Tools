use strict;
use warnings;
use Test2::V0;
use Future;
use IO::Async::Loop;

use lib 'lib';
use PAGI::Middleware::ErrorHandler;
use PAGI::Exception::HTTP;
use PAGI::Headers;
use PAGI::Response qw(response);
use PAGI::ErrorContext qw(error_context);

# An HTTP exception carries headers: the built-in answer sends them, and a
# status HTTP says must carry a field (401, 405, 407, 426) is answered by
# the built-in response when the exception supplies that field.

my $loop = IO::Async::Loop->new;

{
    # A third-party exception, recognised by its methods alone.
    package Local::Unavailable;
    sub new { my ($class, %args) = @_; bless {%args}, $class }
    sub status_code { $_[0]{status} // 503 }
    sub headers { $_[0]{headers} }
}
{
    package Local::DyingHeaders;
    our @ISA = ('Local::Unavailable');
    sub headers { die "no headers here\n" }
}

# Runs one request; returns (status, header pairs, body, failure, warnings, reported).
sub run {
    my (%args) = @_;
    my (@events, @warnings, @reported);
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $mw = PAGI::Middleware::ErrorHandler->new(
        on_error => sub { push @reported, $_[0]; Future->done },
        %{ $args{options} // {} },
    );
    my $f = Future->wrap($mw->wrap(sub { die $args{error} })->(
        { type => 'http', method => 'GET', path => '/', headers => [] },
        sub { Future->done({ type => 'http.disconnect' }) },
        sub { push @events, $_[0]; Future->done },
    ));
    $loop->await($f->else(sub { Future->done }));
    my ($start) = grep { $_->{type} eq 'http.response.start' } @events;
    my $body = join '', map { $_->{body} // '' } grep { $_->{type} eq 'http.response.body' } @events;
    return ($start ? $start->{status} : undef, $start ? $start->{headers} : [], $body,
        $f->is_failed ? ($f->failure)[0] : undef, \@warnings, \@reported);
}

sub values_of {
    my ($pairs, $name) = @_;
    return [ map { $_->[1] } grep { lc($_->[0]) eq lc $name } @$pairs ];
}

subtest 'the constructor takes headers in the three shapes' => sub {
    my $headers = PAGI::Headers->new;
    $headers->add('Retry-After' => '30');
    for my $shape (
        [ flat    => [ 'Retry-After' => '30' ] ],
        [ pairs   => [ [ 'Retry-After' => '30' ] ] ],
        [ object  => $headers ],
    ) {
        my ($label, $given) = @$shape;
        my $e = PAGI::Exception::HTTP->new(503, 'Down for maintenance.', headers => $given);
        is($e->headers, [ [ 'Retry-After' => '30' ] ], "$label: normalized to pairs");
    }
    is(PAGI::Exception::HTTP->new(404)->headers, [], 'no headers: an empty list');
    like(dies { PAGI::Exception::HTTP->throw(503, 'x', headers => [ 'Retry-After' => '30' ]) },
        qr/\A503 x/, 'throw takes them too');
};

subtest 'a malformed headers argument croaks at construction' => sub {
    like(dies { PAGI::Exception::HTTP->new(503, 'x', headers => { a => 1 }) },
        qr/headers must be a flat/, 'a wrong shape');
    like(dies { PAGI::Exception::HTTP->new(503, 'x', headers => [ 'Bad Name' => 'v' ]) },
        qr/Bad Name/, 'a name that is not an HTTP token');
    like(dies { PAGI::Exception::HTTP->new(503, 'x', headers => [ 'X-Wide' => "\x{263A}" ]) },
        qr/X-Wide.*0xFF/, 'a value with a character above 0xFF');
    like(dies { PAGI::Exception::HTTP->new(503, 'x', headers => [ 'Retry-After' => '30' ], colour => 1) },
        qr/Unknown PAGI::Exception::HTTP option: colour/, 'an unknown option');
};

subtest 'the built-in answer carries the headers' => sub {
    my ($status, $pairs, $body, $failure, $warnings) = run(error =>
        PAGI::Exception::HTTP->new(503, 'Down for maintenance.',
            headers => [ 'Retry-After' => '30', 'X-Note' => 'a', 'X-Note' => 'b' ]));
    is($status, 503, 'the status');
    is(values_of($pairs, 'Retry-After'), ['30'], 'a header');
    is(values_of($pairs, 'X-Note'), ['a', 'b'], 'repeated headers, in order');
    is(values_of($pairs, 'Cache-Control'), ['no-store'], 'the no-store default stands');
    is(values_of($pairs, 'Content-Type'), ['text/plain; charset=utf-8'], 'plain text');
    is($warnings, [], 'nothing is diagnosed');

    ($status, $pairs) = run(error => PAGI::Exception::HTTP->new(404, 'Gone.',
        headers => [ 'Cache-Control' => 'max-age=60' ]));
    is(values_of($pairs, 'Cache-Control'), ['max-age=60'], "the exception's Cache-Control wins");

    ($status, $pairs) = run(error => PAGI::Exception::HTTP->new(404, 'Gone.',
        headers => [ 'Content-Type' => 'text/csv' ]));
    is(values_of($pairs, 'Content-Type'), ['text/csv; charset=utf-8'],
        "a Content-Type follows the answer class's rule");
};

subtest 'a field-required status is answered when the exception carries the field' => sub {
    for my $case ([401, 'WWW-Authenticate', 'Bearer'], [405, 'Allow', 'GET, HEAD'],
                  [407, 'Proxy-Authenticate', 'Basic'], [426, 'Upgrade', 'websocket']) {
        my ($code, $field, $value) = @$case;
        my ($status, $pairs, undef, undef, $warnings) = run(error =>
            PAGI::Exception::HTTP->new($code, undef, headers => [ lc($field) => $value ]));
        is($status, $code, "$code with $field: answered");
        is(values_of($pairs, $field), [$value], "$code: $field sent");
        is($warnings, [], "$code: nothing diagnosed");

        ($status, undef, undef, undef, $warnings) = run(error => PAGI::Exception::HTTP->new($code));
        is($status, 500, "$code without $field: a 500");
        like($warnings, [ qr/status $code must carry \Q$field\E/ ], "$code: diagnosed");
    }
};

subtest 'a duck-typed exception with headers' => sub {
    my ($status, $pairs, undef, undef, $warnings) = run(error =>
        Local::Unavailable->new(headers => [ [ 'Retry-After' => '120' ] ]));
    is($status, 503, 'its status');
    is(values_of($pairs, 'Retry-After'), ['120'], 'its headers');
    is($warnings, [], 'nothing diagnosed');

    ($status, $pairs) = run(error =>
        Local::Unavailable->new(status => 401, headers => [ 'WWW-Authenticate' => 'Bearer' ]));
    is($status, 401, 'a field-required status it supplies the field for');
};

subtest "a duck-typed exception's malformed headers give a 500" => sub {
    for my $case (
        [ 'a wrong shape',   { a => 1 },                     qr/headers must be a flat/ ],
        [ 'a bad name',      [ 'Bad Name' => 'v' ],          qr/Bad Name/ ],
        [ 'a wide value',    [ 'X-Wide' => "\x{263A}" ],     qr/X-Wide.*0xFF/ ],
        [ 'a dying method',  undef,                          qr/headers accessor failed/ ],
    ) {
        my ($label, $headers, $diagnostic) = @$case;
        my $error = defined $headers
            ? Local::Unavailable->new(headers => $headers)
            : Local::DyingHeaders->new;
        my ($status, $pairs, $body, $failure, $warnings, $reported) = run(error => $error);
        is($status, 500, "$label: a 500");
        is(values_of($pairs, 'X-Wide'), [], "$label: no header from it is sent");
        like($warnings, [ $diagnostic ], "$label: diagnosed");
        ok($reported->[0] == $error, "$label: on_error sees the original exception");
        ok($failure == $error, "$label: the original exception is re-raised");
    }
};

subtest "a handler or catch entry answers whatever the exception's headers are" => sub {
    # Only the built-in answer sends an exception's headers, so only it needs
    # them sendable: when a handler or a catch entry answers, unsendable
    # headers neither change the status nor are diagnosed.
    my @seen;
    my %answerer = (
        'catch by class' => { catch => { 'Local::Unavailable' => sub {
            push @seen, $_[1]->status;
            response('JSON', { error => 'unavailable' });
        } } },
        catch => { catch => { 503 => sub {
            push @seen, $_[1]->status;
            response('JSON', { error => 'unavailable' });
        } } },
        'catch returning the default' => { catch => { 503 => sub { $_[1]->default } } },
    );
    for my $case (
        [ 'a wrong shape',   { a => 1 } ],
        [ 'a bad name',      [ 'Bad Name' => 'v' ] ],
        [ 'a wide value',    [ 'X-Wide' => "\x{263A}" ] ],
        [ 'a dying method',  undef ],
    ) {
        my ($label, $headers) = @$case;
        for my $by (sort keys %answerer) {
            @seen = ();
            my $error = defined $headers
                ? Local::Unavailable->new(headers => $headers)
                : Local::DyingHeaders->new;
            my ($status, $pairs, undef, undef, $warnings) = run(error => $error, options => $answerer{$by});
            is($status, 503, "$label, $by: the exception's status");
            is(values_of($pairs, 'X-Wide'), [], "$label, $by: no header from it is sent");
            is($warnings, [], "$label, $by: nothing diagnosed");
            is(\@seen, [503], "$label, $by: the answerer is told 503") unless $by =~ /default/;
        }
    }
};

subtest 'a custom catch entry gets no automatic merge' => sub {
    my ($status, $pairs) = run(
        error   => PAGI::Exception::HTTP->new(503, 'x', headers => [ 'Retry-After' => '30' ]),
        options => { catch => { 503 => sub { response('Text', 'custom', status => 503) } } },
    );
    is($status, 503, 'its answer');
    is(values_of($pairs, 'Retry-After'), [], 'without the exception headers');
};

done_testing;
