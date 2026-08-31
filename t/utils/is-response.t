use strict;
use warnings;
use Test2::V0;
use PAGI::Utils ();

ok(!PAGI::Utils->can('is_response'),
    'Utils exposes no is_response implementation');
ok(!grep({ $_ eq 'is_response' } @PAGI::Utils::EXPORT_OK),
    'Utils does not advertise is_response as an optional export');

my $imported = eval q{
    package T::RemovedIsResponseImport;
    PAGI::Utils->import('is_response');
    1;
};
ok(!$imported, 'Utils cannot export is_response');
like($@, qr/is_response.*not exported|not exported.*is_response/i,
    'removed export reports the normal Exporter diagnostic');

done_testing;
