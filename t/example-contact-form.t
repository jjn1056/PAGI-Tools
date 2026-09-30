use strict;
use warnings;
use Test2::V0;
use File::Path qw(remove_tree);
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

# The contact form: a POST route whose handler takes one PAGI::Request and
# returns a JSON Response, static files on an HTTP catch-all route, and the
# upload directory created by a Compose lifespan hook.

my $dir    = "$Bin/../examples/contact-form";
my $file   = "$dir/app.pl";
my $source = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };

like($source, qr/route\('\/submit'\s*=>\s*\\&submit,\s*methods\s*=>\s*\['POST'\]\)/,
    'the form posts to a one-Request handler');
like($source, qr/route\('\/\*path'\s*=>\s*PAGI::App::File->from_app_path\('public'\)\)/,
    'static files are an HTTP catch-all route');
like($source, qr/lifespan\s*=>\s*\{/, 'lifespan hooks come from Compose');
unlike($source, qr/\(\$scope,\s*\$receive,\s*\$send\)|invoke_app|lifespan\.startup/,
    'no raw PAGI application or hand-written lifespan loop');

my $uploads = "$dir/uploads";
my $had_uploads = -d $uploads;

my $app = do $file;
is($@, '', 'the example loads');
isa_ok($app, 'PAGI::Compose');

sub multipart {
    my (%part) = @_;
    my $boundary = 'XtestBOUNDARYx';
    my $body = '';
    for my $name (sort keys %part) {
        my $value = $part{$name};
        if (ref $value) {
            $body .= "--$boundary\r\nContent-Disposition: form-data; name=\"$name\"; "
                . "filename=\"$value->{filename}\"\r\nContent-Type: $value->{type}\r\n\r\n"
                . "$value->{content}\r\n";
        }
        else {
            $body .= "--$boundary\r\nContent-Disposition: form-data; name=\"$name\"\r\n\r\n$value\r\n";
        }
    }
    $body .= "--$boundary--\r\n";
    return (body => $body,
        headers => { 'Content-Type' => "multipart/form-data; boundary=$boundary" });
}

my ($stderr, %res) = ('');
{
    local *STDERR;
    open STDERR, '>', \$stderr or die $!;
    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;
        $res{page}    = $client->get('/');
        $res{missing} = $client->post('/submit', form => { subject => 'general' });
        $res{ok}      = $client->post('/submit', multipart(
            name => 'Ada', email => 'ada@example.com', message => 'Hello',
            attachment => { filename => 'note.txt', type => 'text/plain', content => 'hi there' },
        ));
        $res{bad_type} = $client->post('/submit', multipart(
            name => 'Ada', email => 'ada@example.com', message => 'Hello',
            attachment => { filename => 'x.svg', type => 'image/svg+xml', content => '<svg/>' },
        ));
    });
}

is($res{page}->status, 200, 'the form page is served');
like($res{page}->text, qr/Contact Form/, 'from public/');

is($res{missing}->status, 400, 'a submission missing fields is rejected');
is([sort @{ $res{missing}->json->{errors} }],
    ['Email is required', 'Invalid email format', 'Message is required', 'Name is required'],
    'naming every problem');

is($res{ok}->status, 200, 'a valid submission is accepted');
my $saved = $res{ok}->json->{data}{attachment};
like($saved, qr/\A\d+-\d+\.txt\z/, 'the attachment gets a safe server-side name');
ok(-f "$uploads/$saved", 'and is saved in the upload directory');

is($res{bad_type}->status, 400, 'a disallowed attachment type is rejected');
like($res{bad_type}->json->{errors}[0], qr/File type not allowed: image\/svg\+xml/, 'with the type named');

like($stderr, qr/\[lifespan\] Contact form app started/, 'the startup hook ran');

unlink "$uploads/$saved" if $saved;
remove_tree($uploads) unless $had_uploads;

done_testing;
