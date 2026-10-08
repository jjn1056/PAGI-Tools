#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';

use PAGI::ResponseBuilder;
use PAGI::Test::Client;

# An exact class for as('+...'); response() accepts it once loaded.
BEGIN {
    package My::Test::Response;
    our @ISA = ('PAGI::Response::Text');
    require PAGI::Response::Text;
    $INC{'My/Test/Response.pm'} = __FILE__;
}

# A subclass with a key of its own named like old builder state.
BEGIN {
    package My::Framework::Response;
    our @ISA = ('PAGI::ResponseBuilder');
    sub new { my $self = PAGI::ResponseBuilder::new(shift); $self->{_status} = 'mine'; $self }
}

sub builder { PAGI::ResponseBuilder->new }
sub sent    { PAGI::Test::Client->new(app => $_[0]->to_app)->get('/') }

subtest 'new takes no arguments' => sub {
    isa_ok builder(), 'PAGI::ResponseBuilder';
    like dies { PAGI::ResponseBuilder->new(status => 200) }, qr/takes no arguments/;
};

subtest 'state collected before text reaches the value' => sub {
    my $res = sent(builder()->status(201)->header('X-One' => 'a')
        ->cookie(session => 'abc')->text("caf\x{e9}"));
    is $res->status, 201, 'status';
    is $res->header('x-one'), 'a', 'header';
    is $res->header('set-cookie'), 'session=abc; path=/', 'cookie';
    is $res->content_type, 'text/plain; charset=utf-8', "Text's default type";
    is $res->text, "caf\x{e9}", 'body';
};

subtest 'a header and a cookie after json are sent, and a later body keeps them' => sub {
    my $b = builder()->json({ok => 1})->header('X-After' => 'yes')->cookie(late => 1);
    my $res = sent($b);
    is $res->header('x-after'), 'yes';
    is $res->header('set-cookie'), 'late=1; path=/';
    $res = sent($b->text('replaced'));
    is $res->text, 'replaced', 'the new body';
    is $res->header('x-after'), 'yes', 'header kept across the new body';
    is $res->header('set-cookie'), 'late=1; path=/', 'cookie kept across the new body';
};

subtest 'a refused status leaves the builder unchanged' => sub {
    my $b = builder()->status(201)->text('a');
    like dies { $b->status(204) }, qr/response body is forbidden for status 204/;
    is $b->status, 201, 'status unchanged';
    is sent($b)->status, 201, 'value unchanged';
    my $r = builder()->redirect('/x');
    like dies { $r->status(301) }, qr/Redirect status is response-owned/;
    is $r->status, 302, "the Redirect keeps its own status";
};

subtest 'redirecting twice' => sub {
    my $res = sent(builder()->redirect('/a', 301)->redirect('/b', 302));
    is $res->status, 302;
    is $res->location, '/b';
};

subtest 'a Problem and a redirect replace each other' => sub {
    my $b = builder()->as('Problem', { title => 'Bad', status => 400 });
    is sent($b->redirect('/next'))->status, 302, 'Problem replaced by a redirect';
    is sent($b->as('Problem', { title => 'Bad', status => 400 }))->status, 400,
        'redirect replaced by a Problem';
};

subtest "a redirect's status does not stick" => sub {
    is sent(builder()->redirect('/x')->text('hi'))->status, 200, 'redirect then text';
    is sent(builder()->as('Redirect', '/x')->text('hi'))->status, 200, "as('Redirect') then text";
};

subtest 'a collected status reaches as() but not redirect()' => sub {
    is sent(builder()->status_try(200)->redirect('/x'))->status, 302, 'redirect passes its own';
    my $b = builder()->status_try(200)->text('kept');
    like dies { $b->as('Redirect', '/x') }, qr/Redirect status must be one of/;
    is sent($b)->text, 'kept', 'the builder is unchanged after the failure';
};

subtest 'a failed body leaves the builder untouched' => sub {
    my $b = builder()->status(201)->text('a');
    like dies { $b->json({ x => sub { 1 } }) }, qr/JSON can only represent/;
    my $res = sent($b);
    is $res->status, 201;
    is $res->text, 'a';
};

subtest 'removed cookies stay removed' => sub {
    my $b = builder()->cookie(session => 'old')->text('first');
    $b->remove_header('Set-Cookie');
    is sent($b->json({ok => 1}))->header_all('set-cookie'), [], 'not replayed by the rebuild';
};

subtest 'removal is case-insensitive' => sub {
    my $b = builder()->cookie(a => 1);
    $b->remove_header('set-cookie');
    is sent($b->text('x'))->header_all('set-cookie'), [];
};

subtest 'header order is call order' => sub {
    my $res = sent(builder()->cookie(a => 1)->header('Set-Cookie' => 'raw=2')
        ->cookie(b => 3)->text('x'));
    is $res->header_all('set-cookie'), ['a=1; path=/', 'raw=2', 'b=3; path=/'];
};

subtest 'clearing the type gives the class default, before or after the body' => sub {
    is sent(builder()->content_type('text/csv')->content_type(undef)->text('x'))->content_type,
        'text/plain; charset=utf-8', 'cleared before text';
    is sent(builder()->content_type('text/csv')->text('x')->content_type(undef))->content_type,
        'text/plain; charset=utf-8', 'cleared after text';
    # File has no default; it chooses application/octet-stream itself when sent
    is builder()->file(__FILE__)->content_type('text/x-perl')->content_type(undef)
        ->content_type, undef, 'File has no default';
    is sent(builder()->text('x')->remove_header('Content-Type'))->content_type,
        'text/plain; charset=utf-8', 'remove_header(Content-Type) is content_type(undef)';
};

subtest 'charset rule' => sub {
    is sent(builder()->header('Content-Type' => 'text/csv')->text('a,b'))->content_type,
        'text/csv; charset=utf-8', 'header(Content-Type) is content_type';
    is sent(builder()->header('content-type' => 'text/csv')->text('a,b'))->content_type,
        'text/csv; charset=utf-8', 'in lower case too';
    is sent(builder()->content_type('application/json')->text('{}'))->content_type,
        'application/json', 'JSON gets no charset';
    is sent(builder()->content_type('application/vnd.api+json')->text('{}'))->content_type,
        'application/vnd.api+json', '+json gets no charset';
    is sent(builder()->content_type('text/csv; charset=latin1')->text('a'))->content_type,
        'text/csv; charset=latin1', 'a named charset is kept';
    is sent(builder()->text('x')->content_type('text/csv'))->content_type,
        'text/csv; charset=utf-8', 'set after the body';
    is sent(builder()->content_type('application/xml')->json({}))->content_type,
        'application/xml', 'not applied to JSON bodies';
};

subtest 'empty means 200' => sub {
    my $res = sent(builder()->content_type('text/plain')->empty);
    is $res->status, 200;
    is $res->content_type, undef, 'no Content-Type';
    is sent(builder()->status(204)->empty)->status, 204, 'a collected status is used';
};

subtest 'response with no body' => sub {
    my $b = builder()->header('X-Only' => 'yes');
    my ($one, $two) = ($b->response, $b->response);
    isa_ok $one, 'PAGI::Response::Empty';
    ok $one != $two, 'a new value each call';
    ok !$b->has_body_source, 'still no body';
    is $one->status, 200;
    is $one->header('X-Only'), 'yes';
};

subtest 'redirect status and content type' => sub {
    is sent(builder()->redirect('/login'))->status, 302;
    is sent(builder()->redirect('/x', 301))->status, 301;
    is sent(builder()->content_type('text/x-r')->redirect('/to'))->content_type, 'text/x-r',
        'a collected type is passed through unchanged';
};

subtest 'as() resolves names like response()' => sub {
    isa_ok builder()->as('+My::Test::Response', 'x')->response, 'My::Test::Response';
    like dies { builder()->as('Nope', 1) }, qr/response\('Nope'\): cannot load/;
};

subtest 'as() refuses options the builder owns' => sub {
    for my $name (qw(status headers content_type)) {
        like dies { builder()->as('JSON', {}, $name => 1) }, qr/as\(\) takes no '$name' option/;
    }
};

subtest 'file options pass through; a missing file fails when sent' => sub {
    my $res = sent(builder()->file(__FILE__, filename => 'r.pl'));
    like $res->header('content-disposition'), qr/r\.pl/, 'filename option reached File';
    my $app = builder()->file('/no/such/file')->to_app;
    my @events;
    my $f = $app->(
        { type => 'http', method => 'GET', path => '/', headers => [] },
        sub { Future->done({ type => 'http.disconnect' }) },
        sub { push @events, $_[0]; Future->done },
    );
    like dies { $f->get }, qr/Cannot inspect selected file/, 'fails while sending';
    is \@events, [], 'before http.response.start';
};

subtest 'text and html are strict' => sub {
    like dies { builder()->text(undef) }, qr/defined Unicode scalar/;
    like dies { builder()->text(bless {}, 'Some::Object') }, qr/defined Unicode scalar/;
    like dies { builder()->text('a', 'b') }, qr/text\(\) takes one argument/;
};

subtest 'refused setters change nothing' => sub {
    my $r = builder()->redirect('/x');
    like dies { $r->header('Location' => '/y') }, qr/Redirect Location is response-owned/;
    is sent($r)->location, '/x';
    my $b = builder();
    like dies { $b->header('X' => undef) }, qr/Header value is required/;
    ok !$b->has_header('X'), 'nothing collected';
    like dies { $b->content_type('text/csv')->header('Content-Type' => undef) },
        qr/Header value is required/, 'Content-Type too: clearing is content_type(undef)';
    is $b->content_type, 'text/csv', 'the collected type is unchanged';
    like dies { $b->status('abc') }, qr/Status must be a number between 100-599/;
    ok !$b->has_status, 'no status collected';
};

subtest 'reads come from the value once there is one' => sub {
    my $b = builder()->header('X-A' => 1);
    is $b->header('X-A'), 1, 'collected';
    $b->file(__FILE__);
    is $b->header('X-A'), 1, 'collected header is on the value';
    is $b->status, 200, 'status from the value';
    ok !$b->has_status, 'Text/File carry no explicit status';
    ok $b->has_body_source;
};

subtest 'stream' => sub {
    my $res = sent(builder()->stream(sub {
        my ($writer) = @_;
        return $writer->write("one\n")->then(sub { $writer->write("two\n") });
    }));
    is $res->text, "one\ntwo\n";
};

subtest 'delete_cookie' => sub {
    like sent(builder()->delete_cookie('session')->text('x'))->header('set-cookie'),
        qr/\Asession=; .*max-age=0/i;
};

subtest 'subclass keys do not collide' => sub {
    my $b = My::Framework::Response->new;
    $b->status(201)->text('x');
    is $b->{_status}, 'mine', "the subclass's key is untouched";
    is sent($b)->status, 201;
};

done_testing;
