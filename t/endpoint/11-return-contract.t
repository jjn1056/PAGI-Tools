use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use PAGI::Request;
use PAGI::Response;
use PAGI::Response::JSON ();
use PAGI::Response::Text ();

{ package T::Ep; use parent 'PAGI::Endpoint::HTTP'; use Future::AsyncAwait;
  async sub get { my ($self, $request) = @_; return PAGI::Response::JSON->new({ hi => 1 }) } }
{ package T::Void; use parent 'PAGI::Endpoint::HTTP'; use Future::AsyncAwait;
  async sub get { my ($self, $request) = @_; return } }
{ package T::Invalid; use parent 'PAGI::Endpoint::HTTP';
  sub get { return 'not a response' } }
{ package T::Count; use parent 'PAGI::Endpoint::HTTP'; use Future::AsyncAwait;
  async sub get { my ($self, $request) = @_; $self->{n}++; return PAGI::Response::Text->new("n=$self->{n}") } }

sub recorder { my @e; my $s = sub { push @e, $_[0]; Future->done }; return ($s, \@e) }

subtest 'HTTP endpoint sends the returned response value' => sub {
    my $app = T::Ep->to_app;
    my ($send, $events) = recorder();
    $app->({ type => 'http', method => 'GET' }, sub { Future->done }, $send)->get;
    is $events->[0]{status}, 200, 'returned value was sent';
    like $events->[1]{body}, qr/hi/, 'body';
};

subtest 'handler returning nothing croaks' => sub {
    like dies { T::Void->new->dispatch(PAGI::Request->new(
        { type => 'http', method => 'GET' }, sub { Future->done },
    ))->get },
        qr/did not return a response/, 'no-return is a loud error';
};

subtest 'handler returning a non-response croaks' => sub {
    like(dies { T::Invalid->new->dispatch(PAGI::Request->new(
        { type => 'http', method => 'GET' }, sub { Future->done },
    ))->get },
        qr/T::Invalid->get did not return a response/,
        'invalid return retains the Endpoint diagnostic');
};

subtest '405 for unhandled method, with Allow' => sub {
    my $app = T::Ep->to_app;
    my ($send, $events) = recorder();
    $app->({ type => 'http', method => 'POST' }, sub { Future->done }, $send)->get;
    is $events->[0]{status}, 405, '405 method not allowed';
    my %h = map { lc($_->[0]) => $_->[1] } @{$events->[0]{headers}};
    like $h{allow}, qr/GET/, 'Allow lists GET';
};

subtest 'OPTIONS auto Allow' => sub {
    my $app = T::Ep->to_app;
    my ($send, $events) = recorder();
    $app->({ type => 'http', method => 'OPTIONS' }, sub { Future->done }, $send)->get;
    my %h = map { lc($_->[0]) => $_->[1] } @{$events->[0]{headers}};
    like $h{allow}, qr/GET/, 'OPTIONS lists Allow';
};

subtest 'singleton instance persists across requests' => sub {
    my $app = T::Count->to_app;
    my ($s1, $e1) = recorder();
    $app->({ type => 'http', method => 'GET' }, sub { Future->done }, $s1)->get;
    my ($s2, $e2) = recorder();
    $app->({ type => 'http', method => 'GET' }, sub { Future->done }, $s2)->get;
    is $e1->[1]{body}, 'n=1', 'first request';
    is $e2->[1]{body}, 'n=2', 'second request reuses the same instance (singleton)';
};

done_testing;
