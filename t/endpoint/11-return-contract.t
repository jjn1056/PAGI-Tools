use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use PAGI::Request;
use PAGI::Response;
use PAGI::Response::JSON ();
use PAGI::Response::Text ();
use PAGI::Pages ();
use PAGI::Utils qw(as_app_object);

{ package T::Ep; use parent 'PAGI::Endpoint::HTTP'; use Future::AsyncAwait;
  async sub get { my ($self, $request) = @_; return PAGI::Response::JSON->new({ hi => 1 }) } }
{ package T::Void; use parent 'PAGI::Endpoint::HTTP'; use Future::AsyncAwait;
  async sub get { my ($self, $request) = @_; return } }
{ package T::Invalid; use parent 'PAGI::Endpoint::HTTP';
  sub get { return 'not an application' } }
{ package T::Count; use parent 'PAGI::Endpoint::HTTP'; use Future::AsyncAwait;
  async sub get { my ($self, $request) = @_; $self->{n}++; return PAGI::Response::Text->new("n=$self->{n}") } }
{ package T::Value; use parent 'PAGI::Endpoint::HTTP';
  sub get { my ($self) = @_; return $self->{value} } }
{ package T::FutureValue; use parent 'PAGI::Endpoint::HTTP';
  sub get { my ($self) = @_; return Future->done($self->{value}) } }
{ package T::EndpointRespondOnly; sub new { bless {}, shift } sub respond { Future->done } }
{ package T::EndpointToAppOnly;
  sub new { bless { builds => 0 }, shift }
  sub to_app {
      my ($self) = @_;
      ++$self->{builds};
      return sub {
          my ($scope, $receive, $send) = @_;
          return $send->({ type => 'http.response.start', status => 202, headers => [] })
              ->then(sub { $send->({ type => 'http.response.body', body => 'to-app', more => 0 }) });
      };
  }
}
{ package T::Configured;
  use parent 'PAGI::Endpoint::HTTP';
  sub get {
      my ($self) = @_;
      ++$self->{calls};
      return PAGI::Response::Text->new("$self->{label}:$self->{calls}");
  }
}

sub recorder { my @e; my $s = sub { push @e, $_[0]; Future->done }; return ($s, \@e) }

subtest 'HTTP endpoint sends the returned response value' => sub {
    my $app = T::Ep->to_app;
    my ($send, $events) = recorder();
    $app->({ type => 'http', method => 'GET' }, sub { Future->done }, $send)->get;
    is $events->[0]{status}, 200, 'returned value was sent';
    like $events->[1]{body}, qr/hi/, 'body';
};

subtest 'handler returning a non-application croaks before invocation' => sub {
    for my $case (
        ['nothing', T::Void->new],
        ['string', T::Invalid->new],
        ['hash', T::Value->new(value => {})],
    ) {
        my ($label, $endpoint) = @$case;
        like(dies { $endpoint->dispatch(PAGI::Request->new(
            { type => 'http', method => 'GET' }, sub { Future->done },
        ))->get }, qr/PAGI application|native coderef or app object/,
            "$label is rejected at the Endpoint boundary");
    }
};

subtest 'dispatch retains immediate and Future application values exactly' => sub {
    my $request = PAGI::Request->new(
        { type => 'http', method => 'GET' }, sub { Future->done },
    );
    my $response = PAGI::Response::Text->new('exact response');
    my $pages = PAGI::Pages->not_found;
    my $native = as_app_object(sub { return Future->done });
    my $object = T::EndpointToAppOnly->new;

    for my $case (
        ['response', T::Value->new(value => $response), $response],
        ['Future response', T::FutureValue->new(value => $response), $response],
        ['pages', T::Value->new(value => $pages), $pages],
        ['native app', T::Value->new(value => $native), $native],
        ['app object', T::Value->new(value => $object), $object],
    ) {
        my ($label, $endpoint, $expected) = @$case;
        is($endpoint->dispatch($request)->get, $expected,
            "$label retains its exact application instance");
    }
    is($object->{builds}, 0, 'dispatch validates without compiling an app object');
};

subtest 'to_app invokes the returned application value' => sub {
    my $object = T::EndpointToAppOnly->new;
    my ($send, $events) = recorder();
    T::Value->new(value => $object)->to_app->(
        { type => 'http', method => 'GET' }, sub { Future->done }, $send,
    )->get;
    is($object->{builds}, 1, 'the selected application compiles once');
    is($events->[0]{status}, 202, 'the selected application owns the response');
    is($events->[1]{body}, 'to-app', 'the selected application emitted its body');
};

subtest 'configured object to_app captures its exact instance across requests' => sub {
    my $endpoint = T::Configured->new(label => 'configured');
    my $app = $endpoint->to_app;
    my ($first_send, $first_events) = recorder();
    my ($second_send, $second_events) = recorder();
    $app->({ type => 'http', method => 'GET' }, sub { Future->done }, $first_send)->get;
    $app->({ type => 'http', method => 'GET' }, sub { Future->done }, $second_send)->get;
    is([$first_events->[1]{body}, $second_events->[1]{body}],
        ['configured:1', 'configured:2'],
        'the configured endpoint state persists on its exact receiver');
    is($endpoint->{calls}, 2, 'to_app did not allocate a different endpoint object');
};

subtest 'respond-only objects remain invalid application values' => sub {
    like(dies {
        T::Value->new(value => T::EndpointRespondOnly->new)->dispatch(
            PAGI::Request->new(
                { type => 'http', method => 'GET' }, sub { Future->done },
            ),
        )->get;
    }, qr/PAGI application|native coderef or app object/,
        'respond is not an application-value escape hatch');
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
