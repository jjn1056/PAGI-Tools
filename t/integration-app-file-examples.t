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

my @cases = (
    {
        name  => 'endpoint demo',
        file  => "$Bin/../examples/endpoint-demo/app.pl",
        title => qr/PAGI Endpoint Demo/,
        shape => qr{mount\('/'\s*=>\s*PAGI::App::File->app_path\('public'\)\s*\)},
    },
    {
        name  => 'SSE dashboard',
        file  => "$Bin/../examples/sse-dashboard/app.pl",
        title => qr/PAGI Live Dashboard/,
        shape => qr{PAGI::App::File->app_path\('public'\)->to_app},
    },
    {
        name  => 'contact form',
        file  => "$Bin/../examples/13-contact-form/app.pl",
        title => qr/Contact Form/,
        shape => qr{PAGI::App::File->app_path\('public'\)->to_app},
    },
);

for my $case (@cases) {
    subtest $case->{name} => sub {
        my $source = source_text($case->{file});
        like($source, $case->{shape}, 'uses the application-relative constructor');
        unlike($source, qr/PAGI::App::File->new\s*\(/,
            'contains no manual App File constructor');

        local $ENV{PAGI_HOME};
        delete $ENV{PAGI_HOME};
        local $ENV{PAGI_ENV} = 'production';
        my $app = do $case->{file};
        my $load_error = $@ || $!;
        ok(!$load_error, 'loads cleanly') or diag($load_error);
        is(ref($app), 'CODE', 'returns a native PAGI application');

        SKIP: {
            skip 'example did not load', ($case->{name} eq 'endpoint demo' ? 5 : 2)
                unless ref($app) eq 'CODE';
            my $client = PAGI::Test::Client->new(app => $app);
            my $response = $client->get('/');
            is($response->status, 200, 'static index responds');
            like($response->text, $case->{title}, 'index comes from the public root');

            if ($case->{name} eq 'endpoint demo') {
                my $missing = $client->get('/not-a-static-file');
                is($missing->status, 404,
                    'unresolved endpoint-demo root request is complete');
                ok(defined $missing->content,
                    'unresolved root request includes a terminal body');
                is($missing->content_length, length($missing->content),
                    'unresolved root response advertises its complete body');
            }
        }
    };
}

my $endpoint = source_text($cases[0]{file});
unlike($endpoint, qr/File::Basename|File::Spec|dirname\s*\(/,
    'endpoint demo has no obsolete path arithmetic');

my $dashboard = source_text($cases[1]{file});
unlike($dashboard, qr/File::Basename|File::Spec|dirname\s*\(/,
    'SSE dashboard has no obsolete path arithmetic');

my $contact = source_text($cases[2]{file});
like($contact,
    qr/my \$UPLOAD_DIR = File::Spec->catdir\(dirname\(__FILE__\), 'uploads'\)/,
    'contact form retains its explicit writable upload path');
unlike($contact, qr/\$PUBLIC_DIR/,
    'contact form no longer calculates a static public path');

done_testing;
