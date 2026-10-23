use strict;
use warnings;
use Test2::V0;

use lib 't/lib';
use PAGI::Response qw(response);
use PAGI::Response::Stream ();
use PAGI::Test::Client;

# The base class writes its default application/octet-stream only when its
# body has bytes (R2, signed off by John 2026-10-18); undef content is an
# empty body in the base class only; new() with no arguments is the empty
# staging value.

subtest 'new() is the empty staging value' => sub {
    my $staged = PAGI::Response->new;
    ok(!$staged->has_status, 'no explicit status');
    ok(!$staged->has_content_type, 'no Content-Type');
    is($staged->body, '', 'an empty body');

    my $sent = PAGI::Test::Client->new(app => $staged->to_app)->get('/');
    is($sent->status, 200, 'as an application it sends 200');
    is($sent->content, '', 'with an empty body');
    is($sent->header('Content-Type'), undef, 'and no Content-Type');
};

subtest 'an empty base body has no default Content-Type' => sub {
    ok(!PAGI::Response->new(undef)->has_content_type, 'new(undef)');
    is(PAGI::Response->new(undef)->body, '', 'undef content is an empty body');
    ok(!PAGI::Response->new('')->has_content_type, "new('')");

    my $redirect = response('+PAGI::Response', undef, status => 302, headers => [Location => '/x']);
    ok(!$redirect->has_content_type, 'an empty untyped redirect');
    is($redirect->header('Location'), '/x', 'keeps its Location');

    my $cleared = PAGI::Response->new('')->content_type('image/png')->content_type(undef);
    ok(!$cleared->has_content_type, 'clearing the type of an empty body leaves none');
};

subtest 'the default still applies to a body with bytes' => sub {
    is(PAGI::Response->new('x')->content_type, 'application/octet-stream', "new('x')");
    is(PAGI::Response->new('0')->content_type, 'application/octet-stream', "new('0'): bytes, though false");
    is(PAGI::Response->new('x')->content_type('image/png')->content_type(undef)->content_type,
        'application/octet-stream', 'clearing the type of a body with bytes gives the default back');
    is(PAGI::Response->new('', content_type => 'image/png')->content_type, 'image/png',
        'an explicit type on an empty body is kept');
};

subtest 'typed and unbuffered classes keep their defaults' => sub {
    is(response('Text', '')->content_type, 'text/plain; charset=utf-8', 'empty Text');
    is(response('HTML', '')->content_type, 'text/html; charset=utf-8', 'empty HTML');
    is(PAGI::Response::Stream->new(sub { })->content_type, 'application/octet-stream',
        'a Stream, built through an empty buffered constructor, keeps octet-stream');
};

subtest 'undef keeps its meaning outside the base class' => sub {
    is(response('JSON', undef)->body, 'null', 'JSON renders undef as null');
    like(dies { response('Text', undef) }, qr/./, 'Text still refuses undef');
};

subtest 'options given without content say that content comes first' => sub {
    like(dies { PAGI::Response->new(status => 302) },
        qr/response options must be name\/value pairs \(the content comes first; undef for none\)/,
        'new(status => 302)');
};

done_testing;
