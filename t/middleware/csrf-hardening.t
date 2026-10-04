use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Middleware::CSRF;

# Runs one request through $mw around an app that answers 200 'app'.
# Returns the sent events and the scopes the app saw.
sub run_csrf {
    my ($mw, %request) = @_;
    my (@sent, @seen);
    my $wrapped = $mw->wrap(async sub {
        my ($scope, $receive, $send) = @_;
        push @seen, $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'app', more => 0 });
    });
    $wrapped->(
        {
            type    => $request{type} // 'http',
            path    => '/submit',
            method  => $request{method} // 'POST',
            headers => $request{headers} // [],
            %{ $request{scope} // {} },
        },
        async sub { { type => 'http.disconnect' } },
        async sub { my ($event) = @_; push @sent, $event; return },
    )->get;
    return (\@sent, \@seen);
}

# The CSRF cookie set on the first sent event, or undef.
sub set_cookie_of {
    my ($sent) = @_;
    my ($cookie) = map { $_->[1] }
        grep { lc($_->[0]) eq 'set-cookie' && $_->[1] =~ /\Acsrf_token=/ }
        @{ $sent->[0]{headers} // [] };
    return $cookie;
}

subtest 'secret is removed' => sub {
    like(dies { PAGI::Middleware::CSRF->new(secret => 's') },
        qr/\QCSRF no longer takes a secret: its tokens are random; for tokens bound to the session use session => 1\E/,
        'passing secret dies, naming the replacement');
    ok(lives { PAGI::Middleware::CSRF->new }, 'no option is required');
};

subtest 'tokens are random hex' => sub {
    my $mw = PAGI::Middleware::CSRF->new;
    my (undef, $first)  = run_csrf($mw, method => 'GET');
    my (undef, $second) = run_csrf($mw, method => 'GET');
    like($first->[0]{'pagi.csrf_token'}, qr/\A[0-9a-f]{64}\z/, '64 lowercase hex characters');
    isnt($first->[0]{'pagi.csrf_token'}, $second->[0]{'pagi.csrf_token'}, 'a fresh token per new client');
};

done_testing;
