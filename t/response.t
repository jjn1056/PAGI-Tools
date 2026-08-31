use strict;
use warnings;
use Test2::V0;
use PAGI::Response;

isa_ok(PAGI::Response->new(''), ['PAGI::Response'], 'base response is a complete response value');
ok !PAGI::Response->can('send_raw'), 'raw builder finisher was removed';
ok !PAGI::Response->can('writer'), 'writer takeover was removed';
ok !PAGI::Response->can('send_file'), 'file finisher was removed';
ok !PAGI::Response->can('has_body_source'), 'incomplete-builder predicate was removed';
done_testing;
