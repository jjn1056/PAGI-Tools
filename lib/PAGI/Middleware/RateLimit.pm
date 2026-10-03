package PAGI::Middleware::RateLimit;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future;
use Future::AsyncAwait;
use PAGI::Response::Text ();
use PAGI::Utils ();
use POSIX ();
use Scalar::Util qw(refaddr);
use Time::HiRes ();

=head1 NAME

PAGI::Middleware::RateLimit - Request rate limiting middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'RateLimit',
            requests_per_second => 10,
            burst => 20,
            key_generator => sub  {
        my ($scope) = @_; exists $scope->{client} ? $scope->{client}[0] : 'unknown' };
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::RateLimit implements token bucket rate limiting per client.
A client over its limit is refused with C<429 text/plain>,
C<Rate limit exceeded. Try again later.>, carrying C<Retry-After> and the
C<X-RateLimit-Limit>, C<-Remaining> and C<-Reset> fields; allowed responses
gain the C<X-RateLimit-*> fields. C<refuse> replaces the refusal's body.

B<Treat this as a proof of concept, or a template to build on, not as
production rate limiting.> Its buckets live in the memory of one process (see
L</LIMITATIONS>). It suits a single-process application, development, and
reading how a limiter fits the middleware protocol; a deployment that needs
limits enforced across workers or hosts needs a shared, atomic store, which
this middleware does not have.

=head1 CONFIGURATION

An option not listed here dies at construction.

=over 4

=item * requests_per_second (default: 10)

Average requests allowed per second.

=item * burst (default: 20)

Maximum burst size (bucket capacity).

=item * key_generator (default: client IP)

Coderef to generate rate limit key from $scope.

=item * cleanup_interval (default: 60)

Seconds between periodic cleanup of stale buckets.

=item * max_buckets (default: 10000)

Maximum number of tracked client buckets. When exceeded, the oldest
half are evicted as a safety valve.

=item * refuse (default: a 429 text response)

An application that answers an over-limit request instead of the plain-text
default: a Request handler (a coderef called with one
L<PAGI::Request>, returning a Response or an application) or an object
with C<to_app>, which includes every L<PAGI::Response>:

    middleware('RateLimit', requests_per_second => 5,
        refuse => response('JSON', { detail => 'Slow down' }, status => 429));

The middleware still sets C<Retry-After> and the C<X-RateLimit-*> fields on
whatever it sends, replacing any of the same name. There is no C<0> form. Any
plain value dies.

C<backend> was removed: it was documented as a pluggable store but never used.
Passing it dies.

A native C<($scope, $receive, $send)> application is passed as
C<as_app_object($app)>. Objects -- every Response and L<PAGI::Pages> value --
mean the same in every slot, and are the portable form for anything also
given to middleware outside PAGI-Tools.

=back

=cut

# Each instance's buckets, kept in this process and keyed by the instance,
# so two limiters never share a client's bucket. The class-level helpers
# below reach every instance's buckets.
my %buckets_for;
my $_time_offset = 0;

sub _clear_buckets { %buckets_for = (); $_time_offset = 0; }
sub _bucket_count  { my $count = 0; $count += keys %$_ for values %buckets_for; return $count }
sub _advance_time_for_test { $_time_offset += $_[1] }
sub _now { return Time::HiRes::time() + $_time_offset }

sub DESTROY { delete $buckets_for{refaddr($_[0])} }

sub _init {
    my ($self, $config) = @_;

    $self->{requests_per_second} = $config->{requests_per_second} // 10;
    $self->{burst} = $config->{burst} // 20;
    $self->{key_generator} = $config->{key_generator} // sub  {
        my ($scope) = @_;
        return exists $scope->{client} ? ($scope->{client}[0] // 'unknown') : 'unknown';
    };
    $self->{cleanup_interval} = $config->{cleanup_interval} // 60;
    $self->{max_buckets}      = $config->{max_buckets} // 10_000;

    die "RateLimit 'backend' was removed: it was never used; buckets are kept in this process"
        if exists $config->{backend};

    # The caller's refusing application, or a plain-text default built once.
    # Either way the middleware adds the rate-limit fields to its response.
    $self->{refuse} = PAGI::Utils::_refuse_option('RateLimit', $config)
        // PAGI::Response::Text->new('Rate limit exceeded. Try again later.', status => 429)->to_app;
    PAGI::Utils::_reject_unknown_options('RateLimit', $config,
        qw(burst cleanup_interval key_generator max_buckets refuse
           requests_per_second));
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $key = $self->{key_generator}->($scope);
        my ($allowed, $remaining, $reset) = $self->_check_rate_limit($key);

        if (!$allowed) {
            await $self->_send_rate_limited(
                $scope, $receive, $send, $remaining, $reset,
            );
            return;
        }

        # Add rate limit headers to response
        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                my @headers = @{$event->{headers} // []};
                push @headers, ['X-RateLimit-Limit', $self->{burst}];
                push @headers, ['X-RateLimit-Remaining', $remaining];
                push @headers, ['X-RateLimit-Reset', $reset];
                await $send->({
                    %$event,
                    headers => \@headers,
                });
            } else {
                await $send->($event);
            }
        };

        await $app->($scope, $receive, $wrapped_send);
    };
}

sub _check_rate_limit {
    my ($self, $key) = @_;

    my $now = _now();
    my $rate = $self->{requests_per_second};
    my $burst = $self->{burst};

    # Get or initialize bucket
    my $buckets = $buckets_for{refaddr($self)} //= {};
    my $bucket = $buckets->{$key} //= {
        tokens    => $burst,
        last_time => $now,
    };

    # Refill tokens based on time elapsed
    my $elapsed = $now - $bucket->{last_time};
    my $refill = $elapsed * $rate;
    $bucket->{tokens} = $bucket->{tokens} + $refill;
    $bucket->{tokens} = $burst if $bucket->{tokens} > $burst;
    $bucket->{last_time} = $now;

    # Determine rate limit result
    my @result;
    if ($bucket->{tokens} >= 1) {
        $bucket->{tokens} -= 1;
        my $remaining = int($bucket->{tokens});
        my $reset = POSIX::ceil($now + ($burst - $bucket->{tokens}) / $rate);
        @result = (1, $remaining, $reset);  # Allowed
    } else {
        my $reset = POSIX::ceil($now + (1 - $bucket->{tokens}) / $rate);
        @result = (0, 0, $reset);  # Not allowed
    }

    # Periodic cleanup of stale buckets
    if (!$self->{_last_cleanup} || ($now - $self->{_last_cleanup}) >= $self->{cleanup_interval}) {
        $self->{_last_cleanup} = $now;
        my $stale_threshold = $now - (2 * $burst / $rate);
        for my $k (keys %$buckets) {
            delete $buckets->{$k} if $buckets->{$k}{last_time} < $stale_threshold;
        }
    }

    # Safety valve: evict oldest buckets when over max
    if (keys %$buckets > $self->{max_buckets}) {
        my @sorted = sort { $buckets->{$a}{last_time} <=> $buckets->{$b}{last_time} } keys %$buckets;
        my $to_remove = @sorted - int($self->{max_buckets} / 2);
        delete $buckets->{$_} for @sorted[0 .. $to_remove - 1];
    }

    return @result;
}

async sub _send_rate_limited {
    my ($self, $scope, $receive, $send, $remaining, $reset) = @_;

    my $retry_after = POSIX::ceil($reset - _now());
    $retry_after = 1 if $retry_after < 1;
    my @fields = (
        ['Retry-After',           $retry_after],
        ['X-RateLimit-Limit',     $self->{burst}],
        ['X-RateLimit-Remaining', 0],
        ['X-RateLimit-Reset',     $reset],
    );

    # The rate-limit fields are this middleware's, whoever writes the body.
    await $self->{refuse}->($scope, $receive,
        PAGI::Utils::_send_with_fields($send, @fields));
}

# Class method to reset rate limits (useful for testing)
sub reset_all {
    _clear_buckets();
}

1;

__END__

=head1 RATE LIMITING ALGORITHM

This middleware uses the token bucket algorithm:

=over 4

=item * Each client has a "bucket" that holds tokens

=item * Tokens are added at a constant rate (requests_per_second)

=item * The bucket has a maximum capacity (burst)

=item * Each request consumes one token

=item * If no tokens available, request is rejected

=back

This allows short bursts of traffic while maintaining an average rate.

=head1 LIMITATIONS

=over 4

=item * B<Per process.> Each middleware instance keeps its buckets in the
memory of the process it runs in. Under a pre-fork server each worker has its
own, so the effective limit is the configured one times the number of
workers. Nothing is shared across hosts.

=item * B<Keyed by client address by default.> Behind a proxy every request
comes from the proxy's address, so one bucket covers every client: place
L<PAGI::Middleware::ReverseProxy> first, or pass a C<key_generator>. A request
with no client address shares one C<unknown> bucket. IPv6 clients can change
address freely.

=item * B<A bounded table.> Above C<max_buckets> the oldest half of the
buckets are dropped, so many distinct clients can reset others' limits.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
