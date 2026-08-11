use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use PAGI::Test::Client;

sub source_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!";
    local $/;
    my $source = <$fh>;
    close $fh or die "cannot close $path: $!";
    return $source;
}

my $app_file = "$Bin/../examples/app-01-file/app.pl";
my $source = source_text($app_file);

like($source,
    qr/PAGI::App::File->app_path\('static'\)->to_app/,
    'root-level example uses script-fallback alternate constructor');
unlike($source,
    qr/File::Basename|File::Spec|dirname\s*\(|PAGI::App::File->new\s*\(/,
    'root-level example contains no manual or expanded static-root setup');

local $ENV{PAGI_HOME};
delete $ENV{PAGI_HOME};
local $ENV{PAGI_ENV} = 'production';
my $app = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'file example loads cleanly') or diag($load_error);
is(ref($app), 'CODE', 'file example returns a compiled PAGI app');

SKIP: {
    skip 'example did not load', 6 unless ref($app) eq 'CODE';
    my $client = PAGI::Test::Client->new(app => $app);
    my $index = $client->get('/');
    is($index->status, 200, 'index is served');
    like($index->text, qr/Welcome to PAGI::App::File/,
        'index comes from the example static root');
    like($client->get('/test.txt')->text,
        qr/\AHello from PAGI::App::File!\n/, 'plain fixture is served');
    is($client->get('/data.json')->status, 200, 'JSON fixture is served');
    is($client->get('/subdir/nested.txt')->status, 200,
        'nested fixture is served');
    is($client->get('/missing.txt')->status, 404,
        'missing fixture remains 404');
}

done_testing;
