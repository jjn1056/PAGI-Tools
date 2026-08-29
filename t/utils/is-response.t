use strict;
use warnings;
use Test2::V0;
use PAGI::Utils qw(is_response);
use PAGI::Response;
use PAGI::Test::Response;

{ package T::ResponseSubclass; use parent 'PAGI::Response'; }
{ package T::RespondOnly; sub new { bless {}, shift } sub respond { } }
{ package T::ToAppOnly; sub new { bless {}, shift } sub to_app { } }

ok is_response(PAGI::Response->new('body')), 'complete base value is a response';
ok is_response(T::ResponseSubclass->new('body')), 'Response subclasses retain nominal acceptance';
ok !is_response(T::RespondOnly->new), 'a respond-only duck type is not a Response value';
ok !is_response(T::ToAppOnly->new), 'a to_app-only duck type is not a Response value';
ok !is_response(PAGI::Test::Response->new(events => [])),
    'captured Test::Response data is not an application Response value';
ok !is_response(undef), 'undef is not a response';
done_testing;
