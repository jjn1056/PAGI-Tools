use strict;
use warnings;
use Test2::V0;

use lib 't/lib';
use PAGITest::Stringy;
use PAGI::Response qw(response);

# Every site that takes a string accepts an object whose class overloads ""
# and refuses every other value that is not a string. PAGITest::Stringy holds
# the cases; each site supplies how to reach it and its own refusal message.

PAGITest::Stringy::check_site(
    name    => 'Text body',
    run     => sub { PAGITest::Stringy::body_of(response('Text', $_[0])) },
    refused => qr/Text response body must be a defined Unicode scalar/,
);

PAGITest::Stringy::check_site(
    name    => 'HTML body',
    run     => sub { PAGITest::Stringy::body_of(response('HTML', $_[0])) },
    refused => qr/HTML response body must be a defined Unicode scalar/,
);

PAGITest::Stringy::check_site(
    name    => 'byte body',
    run     => sub { PAGITest::Stringy::body_of(PAGI::Response->new($_[0])) },
    refused => qr/response body must be a defined unblessed scalar of encoded bytes/,
);

PAGITest::Stringy::check_site(
    name    => 'Stream write_text',
    run     => sub { my ($value) = @_; PAGITest::Stringy::body_of(response('Stream', sub { $_[0]->write_text($value) })) },
    refused => qr/stream text must be a defined unblessed character scalar/,
);

PAGITest::Stringy::check_site(
    name    => 'Stream write',
    run     => sub { my ($value) = @_; PAGITest::Stringy::body_of(response('Stream', sub { $_[0]->write($value) })) },
    refused => qr/stream chunk must be a defined unblessed scalar of encoded bytes/,
);

# URLs, and the strings of a problem document.

use JSON::MaybeXS qw(decode_json);
use PAGI::Pages;
use PAGI::Test::Client;
use Scalar::Util ();
use URI;

sub sent { PAGI::Test::Client->new(app => $_[0])->get('/', headers => { Accept => 'application/problem+json' }) }
sub sent_response { sent($_[0]->to_app) }

PAGITest::Stringy::check_site(
    name    => 'Redirect location',
    run     => sub { sent_response(response('Redirect', $_[0]))->header('location') },
    refused => qr/Redirect location must be a URI-reference scalar/,
);
is(sent_response(response('Redirect', URI->new('https://example.com/x')))->header('location'),
    'https://example.com/x', 'a URI object is a redirect target');

for my $member (qw(type instance)) {
    PAGITest::Stringy::check_site(
        name    => "Problem $member",
        run     => sub { decode_json(sent_response(response('Problem', { $member => $_[0] }))->content)->{$member} },
        refused => qr/Problem $member must be a URI-reference scalar/,
    );
}
for my $member (qw(title detail)) {
    PAGITest::Stringy::check_site(
        name    => "Problem $member",
        run     => sub { decode_json(sent_response(response('Problem', { $member => $_[0] }))->content)->{$member} },
        refused => qr/Problem $member must be a string scalar/,
    );
}
{
    my $object = PAGITest::Stringy::Overloaded->new('/problems/x');
    my $document = { type => $object };
    response('Problem', $document);
    is(Scalar::Util::refaddr($document->{type}), Scalar::Util::refaddr($object),
        "the caller's problem document still holds the object");
}

# PAGI::Pages, one rule across the board.

# Pages takes type and title together.
my %with = (title => [type => 'https://example.com/problems/x'], detail => []);
for my $option (qw(detail title)) {
    PAGITest::Stringy::check_site(
        name    => "Pages $option",
        run     => sub { sent(PAGI::Pages->not_found($option => $_[0], @{ $with{$option} }, as => 'json'))->json->{$option} },
        refused => qr/PAGI::Pages $option must be a Unicode scalar/,
    );
}
PAGITest::Stringy::check_site(
    name    => 'Pages type',
    string  => 'https://example.com/problems/x',
    run     => sub { sent(PAGI::Pages->not_found(type => $_[0], title => 'Moved', as => 'json'))->json->{type} },
    refused => qr/PAGI::Pages type must be an absolute URI/,
);
PAGITest::Stringy::check_site(
    name    => 'Pages instance',
    run     => sub { sent(PAGI::Pages->not_found(instance => $_[0], as => 'json'))->json->{instance} },
    refused => qr/PAGI::Pages instance must be a URI-reference scalar/,
);
PAGITest::Stringy::check_site(
    name    => 'Pages redirect target',
    run     => sub { sent(PAGI::Pages->redirect($_[0]))->header('location') },
    refused => qr/PAGI::Pages redirect target must be a URI-reference scalar/,
);
PAGITest::Stringy::check_site(
    name    => 'Pages blocked_by',
    run     => sub { (sent(PAGI::Pages->status(451, blocked_by => $_[0], as => 'json'))->header('link') =~ /\A<([^>]*)>/)[0] },
    refused => qr/PAGI::Pages blocked_by must be a URI-reference scalar/,
);
PAGITest::Stringy::check_site(
    name    => 'Pages login_url',
    run     => sub { sent(PAGI::Pages->status(511, login_url => $_[0], as => 'json'))->json->{login} },
    refused => qr/PAGI::Pages login_url must be a URI-reference scalar/,
);
{
    # favicon_href is a hook: undef means no favicon, so only objects are checked.
    our $favicon;
    package PAGITest::FaviconPages { our @ISA = ('PAGI::Pages'); sub favicon_href { $main::favicon } }
    my $html = sub {
        local $main::favicon = $_[0];
        PAGI::Test::Client->new(app => PAGITest::FaviconPages->not_found(as => 'html'))
            ->get('/', headers => { Accept => 'text/html' });
    };
    like($html->(PAGITest::Stringy::Overloaded->new('/icon.svg'))->content, qr{href="/icon\.svg"},
        'a favicon_href object is used as its string');
    is($html->(PAGITest::Stringy::Plain->new)->status, 500, 'a favicon_href object that does not stringify is refused');
}

# File: its path, and the filename it is sent as.

use File::Temp qw(tempdir);
use Path::Tiny ();

my $files = tempdir(CLEANUP => 1);
my $file = "$files/report.txt";
{ open my $fh, '>', $file or die "$file: $!"; print {$fh} $file; close $fh }    # the file's body is its own path

PAGITest::Stringy::check_site(
    name    => 'File path',
    string  => $file,
    run     => sub { sent_response(response('File', $_[0]))->content },
    refused => qr/File response path must be a defined nonempty scalar string/,
);
PAGITest::Stringy::check_site(
    name    => 'File filename',
    run     => sub { (sent_response(response('File', $file, filename => $_[0]))->header('content-disposition') =~ /filename="([^"]*)"/)[0] },
    refused => qr/File response filename must be a defined scalar/,
);
is(sent_response(response('File', Path::Tiny::path($file)))->content, $file, 'a Path::Tiny path sends the file');

# Header values, Content-Type, cookies, and every header a response sends.

PAGITest::Stringy::check_site(
    name    => 'header value',
    run     => sub { sent_response(response('Text', 'x')->header('X-A' => $_[0]))->header('x-a') },
    refused => qr/Header value is required/,
);
PAGITest::Stringy::check_site(
    name    => 'headers option value',
    run     => sub { sent_response(response('Text', 'x', headers => ['X-A' => $_[0]]))->header('x-a') },
    refused => qr/Header value is required/,
);
like(dies { response('Text', 'x', headers => [['X-A', 1]]) },
    qr/headers must be flat name\/value pairs, not nested pairs/, 'a nested pair is still refused as one');

is(sent_response(PAGI::Response->new('x')->content_type(PAGITest::Stringy::Overloaded->new('text/csv')))
    ->header('content-type'), 'text/csv', 'content_type takes an object that stringifies');
is(sent_response(response('Text', 'x')->content_type(PAGITest::Stringy::Overloaded->new('text/csv')))
    ->header('content-type'), 'text/csv; charset=utf-8', "Text's content_type stringifies before adding its charset");
like(dies { PAGI::Response->new('x')->content_type(PAGITest::Stringy::Plain->new) },
    qr/Content-Type must be a scalar/, 'content_type refuses an object that does not stringify');

sub set_cookie { sent_response($_[0])->header('set-cookie') }
PAGITest::Stringy::check_site(
    name    => 'cookie value',
    run     => sub { (set_cookie(response('Text', 'x')->cookie(c => $_[0])) =~ /\Ac=([^;]*)/)[0] },
    refused => qr/cookie value must be a string or an object that overloads stringification/,
);
like(set_cookie(response('Text', 'x')->cookie(c => 'v', domain => PAGITest::Stringy::Overloaded->new('example.com'),
    path => PAGITest::Stringy::Overloaded->new('/app'))), qr/domain=example\.com; path=\/app/, 'cookie domain and path take objects');
like(dies { response('Text', 'x')->cookie(c => 'v', domain => PAGITest::Stringy::Plain->new) },
    qr/cookie domain must be a string or an object that overloads stringification/,
    'a cookie domain that does not stringify is refused, not sent as HASH(0x...)');
like(set_cookie(response('Text', 'x')->delete_cookie('c', path => PAGITest::Stringy::Overloaded->new('/app'))),
    qr/\Ac=; .*path=\/app/i, 'delete_cookie takes them too');

# Headers added straight to the container are checked as they are sent, on
# every kind of response.
my %kinds = (
    buffered => sub { response('Text', 'x') },
    stream   => sub { response('Stream', sub { $_[0]->write('x') }) },
    file     => sub { response('File', $file) },
);
for my $kind (sort keys %kinds) {
    my $added = $kinds{$kind}->();
    $added->headers->add('X-Obj' => PAGITest::Stringy::Overloaded->new('ok'));
    is(sent_response($added)->header('x-obj'), 'ok', "$kind: a header object added to the container is sent as its string");

    my $plain = $kinds{$kind}->();
    $plain->headers->add('X-Obj' => PAGITest::Stringy::Plain->new);
    like(dies { PAGITest::Stringy::events_of($plain) },
        qr/header 'X-Obj' value must be a string or an object that overloads stringification/,
        "$kind: one that does not stringify is refused, naming the header");
}

done_testing;
