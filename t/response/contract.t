use strict;
use warnings;
use Test2::V0;

use lib 't/lib';
use File::Temp qw(tempfile);
use PAGI::Response qw(response);

# The constructor contract (PAGI::Response, CONSTRUCTOR CONTRACT): every
# shipped class is built as response($name, $content, status => ...,
# headers => ..., content_type => ...), Empty taking no content.

my (undef, $path) = tempfile(UNLINK => 1);

# name => [content, a status it accepts, its documented content-type answer]
my %class = (
    '+PAGI::Response' => [ 'bytes',             201, 'image/png' ],
    'Text'            => [ 'characters',        201, 'text/csv; charset=utf-8' ],
    'HTML'            => [ '<p>hi</p>',         201, 'text/csv; charset=utf-8' ],
    'JSON'            => [ { a => 1 },          201, 'image/png' ],
    'Problem'         => [ { title => 'Nope' }, 409, 'image/png' ],
    'Redirect'        => [ '/elsewhere',        303, 'image/png' ],
    'File'            => [ $path,               201, 'image/png' ],
    'Stream'          => [ sub { },             201, 'image/png' ],
    'NDJSON'          => [ sub { },             201, 'image/png' ],
);
my %asked = (Text => 'text/csv', HTML => 'text/csv');

for my $name (sort keys %class) {
    my ($content, $status, $type) = @{ $class{$name} };
    subtest "$name takes the common options" => sub {
        my $r = response($name, $content,
            status       => $status,
            headers      => [ 'X-One' => 'a', 'X-Two' => 'b', 'X-One' => 'c' ],
            content_type => $asked{$name} // $type,
        );
        is($r->status, $status, 'the status is applied');
        is($r->header_all('X-One'), ['a', 'c'], 'repeated headers keep their order');
        is($r->header('X-Two'), 'b', 'every header is carried');
        is($r->content_type, $type, 'the content type is honoured by the class rule');

        for my $shape (
            [ 'pairs'   => [ [ 'X-One' => 'a' ] ] ],
            [ 'object'  => do { my $h = PAGI::Headers->new; $h->add('X-One' => 'a'); $h } ],
        ) {
            my ($label, $headers) = @$shape;
            is(response($name, $content, headers => $headers)->header('X-One'), 'a',
                "headers as $label");
        }
    };
}

subtest 'Empty takes no content and refuses a Content-Type' => sub {
    my $r = response('Empty', status => 205, headers => [ 'X-One' => 'a' ]);
    is($r->status, 205, 'the status is applied');
    is($r->header('X-One'), 'a', 'headers are carried');
    like(dies { response('Empty', content_type => 'text/plain') },
        qr/Empty response does not permit Content-Type/, 'content_type is refused');
};

subtest "Redirect's statuses" => sub {
    is(response('Redirect', '/x')->status, 302, '302 by default');
    is(response('Redirect', '/x', status => $_)->status, $_, "$_ is accepted")
        for 301, 302, 303, 307, 308;
    like(dies { response('Redirect', '/x', status => 200) }, qr/./, '200 is refused');
};

subtest "Problem's document status agrees with the option" => sub {
    is(response('Problem', { title => 'x', status => 422 })->status, 422,
        'the document status is the HTTP status');
    is(response('Problem', { title => 'x', status => 422 }, status => 422)->status, 422,
        'an equal option is accepted');
    like(dies { response('Problem', { title => 'x', status => 422 }, status => 400) },
        qr/Problem document and HTTP statuses must agree/, 'a different option is refused');
};

subtest 'owned fields are refused in staged headers' => sub {
    like(dies { response('Empty', headers => [ 'Content-Type' => 'text/plain' ]) },
        qr/Empty response does not permit Content-Type/, 'Empty: Content-Type');
    like(dies { response('Redirect', '/x', headers => [ Location => '/y' ]) },
        qr/Location/, 'Redirect: Location');
    for my $field ('Content-Length', 'Content-Range', 'ETag') {
        like(dies { response('File', $path, headers => [ $field => '1' ]) },
            qr/\Q$field\E/i, "File: $field");
    }
};

done_testing;
