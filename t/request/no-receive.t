use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';
use PAGI::Request;

# A Request built from the scope alone, PAGI::Request->new($scope) or
# ->new($scope, undef): it reads what the scope holds, and every body entry
# point dies before it touches a receive or sets a consumption flag.

my $no_body = qr/\Athis Request was built from the scope alone; it has no body at /;

sub scope_with {
    my (%args) = @_;
    return {
        type         => 'http',
        method       => 'POST',
        path         => '/upload',
        query_string => 'page=2',
        headers      => [
            [ 'content-type', $args{content_type} ],
            [ 'x-token', 'abc' ],
        ],
    };
}

# Every field a body entry point sets on the object when it reads or streams.
my @flags = qw(_body_read _body_stream_created _multipart _multipart_form _body _form _uploads);

# A JSON body for body/text/json; a multipart one for the parsers that look
# at the Content-Type, so the check is shown to come before theirs.
my %content_type = (
    json      => 'application/json',
    multipart => 'multipart/form-data; boundary=XyZ',
);

my @entry_points = (
    [ body             => 'json',      sub { $_[0]->body->get } ],
    [ text             => 'json',      sub { $_[0]->text->get } ],
    [ json             => 'json',      sub { $_[0]->json->get } ],
    [ body_stream      => 'json',      sub { $_[0]->body_stream } ],
    [ multipart_stream => 'multipart', sub { $_[0]->multipart_stream } ],
    [ form_params      => 'multipart', sub { $_[0]->form_params->get } ],
    [ form_param       => 'multipart', sub { $_[0]->form_param('a')->get } ],
    [ raw_form_params  => 'multipart', sub { $_[0]->raw_form_params->get } ],
    [ raw_form_param   => 'multipart', sub { $_[0]->raw_form_param('a')->get } ],
    [ uploads          => 'multipart', sub { $_[0]->uploads->get } ],
    [ upload           => 'multipart', sub { $_[0]->upload('a')->get } ],
    [ upload_all       => 'multipart', sub { $_[0]->upload_all('a')->get } ],
);

for my $built ([ 'new($scope)', sub { PAGI::Request->new($_[0]) } ],
               [ 'new($scope, undef)', sub { PAGI::Request->new($_[0], undef) } ]) {
    my ($how, $build) = @$built;

    subtest "$how reads the scope" => sub {
        my $scope = scope_with(content_type => $content_type{json});
        my $request = $build->($scope);
        isa_ok($request, 'PAGI::Request');
        is($request->header('X-Token'), 'abc', 'a header');
        is($request->query_param('page'), '2', 'a query parameter');
        is($request->content_type, 'application/json', 'the content type');
        is($request->path, '/upload', 'the path');
    };

    subtest "$how: every body entry point dies and sets no flag" => sub {
        for my $entry (@entry_points) {
            my ($name, $kind, $call) = @$entry;
            my $request = $build->(scope_with(content_type => $content_type{$kind}));
            like(dies { $call->($request) }, $no_body, "$name dies");
            is([ grep { exists $request->{$_} } @flags ], [], "$name sets no flag");
        }
    };
}

subtest 'a WebSocket scope without a receive gets the same message' => sub {
    my $request = PAGI::Request->new({ type => 'websocket', path => '/ws', headers => [] });
    like(dies { $request->body->get }, $no_body, 'the missing receive is reported first');
};

subtest 'a receive that is not a coderef is still refused' => sub {
    like(dies { PAGI::Request->new(scope_with(content_type => 'text/plain'), 'nope') },
        qr/\APAGI::Request requires a receive coderef at /, 'a string');
};

subtest 'a Request is a PAGI::HTTPConnection' => sub {
    my $receive = sub { Future->done({ type => 'http.request', body => '', more => 0 }) };
    isa_ok(PAGI::Request->new(scope_with(content_type => 'text/plain'), $receive),
        'PAGI::HTTPConnection');
};

done_testing;
