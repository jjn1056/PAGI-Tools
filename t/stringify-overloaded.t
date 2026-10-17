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

done_testing;
