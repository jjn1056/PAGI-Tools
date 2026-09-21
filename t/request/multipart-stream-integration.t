use strict; use warnings;
use Test2::V0;
use Future;
use PAGI::Request;

my $b = 'BOUND';
sub mp_body {
    my ($bd,@rows)=@_; my $s='';
    for my $r (@rows){ my ($n,$f,$ct,$d)=@$r; my $cd=qq{form-data; name="$n"}; $cd.=qq{; filename="$f"} if defined $f;
        $s.="--$bd\r\nContent-Disposition: $cd\r\n"; $s.="Content-Type: $ct\r\n" if defined $ct; $s.="\r\n$d\r\n"; }
    return $s."--$bd--\r\n";
}
my $body = mp_body($b, ['doc','a.txt','text/plain','hi']);

sub req {
    my ($content_type, @chunks) = @_;
    my $scope = { type => 'http', method => 'POST',
        headers => [['content-type', $content_type // "multipart/form-data; boundary=$b"]] };
    my $recv  = sub { my $c = shift @chunks;
        Future->done(defined $c ? {type=>'http.request',body=>$c,more=>(@chunks?1:0)} : {type=>'http.disconnect'}) };
    return PAGI::Request->new($scope, $recv);
}

subtest 'multipart_stream streams a part without spooling' => sub {
    my $stream = req(undef, $body)->multipart_stream;
    my $p = $stream->next->get;
    is $p->filename, 'a.txt', 'got the file part';
    is $p->value->get, 'hi', 'streamed its bytes';
};

subtest 'non-multipart request croaks' => sub {
    my $r = PAGI::Request->new(
        { type=>'http', method=>'POST', headers=>[['content-type','application/json']] },
        sub { Future->done({type=>'http.disconnect'}) });
    like dies { $r->multipart_stream }, qr/multipart/i, 'non-multipart croaks';
};

subtest 'consumed-once latch, both directions' => sub {
    my $r1 = req(undef, $body); $r1->multipart_stream;
    like dies { $r1->form_params->get }, qr/consumed|stream|already/i, 'form_params after multipart_stream croaks';

    my $r2 = req(undef, $body); $r2->form_params->get;
    like dies { $r2->multipart_stream }, qr/consumed|already/i, 'multipart_stream after form_params croaks';

    my $r3 = req(undef, $body); $r3->multipart_stream;
    like dies { $r3->multipart_stream }, qr/consumed|already/i, 'second multipart_stream croaks';
};

subtest 'both Request entry points accept quoted boundaries and reject unusable ones' => sub {
    my $boundary = 'test:boundary';
    my $quoted_body = mp_body($boundary, ['doc', 'a.txt', 'text/plain', 'hi']);
    my $content_type = 'multipart/form-data; boundary="test:boundary"';
    my $part = req($content_type, $quoted_body)->multipart_stream->next->get;
    is $part->filename, 'a.txt', 'streaming boundary retains quoted punctuation';
    is $part->value->get, 'hi', 'streaming body';
    my $uploads = req($content_type, $quoted_body)->uploads->get;
    is $uploads->get('doc')->filename, 'a.txt', 'buffered boundary retains quoted punctuation';

    my $spaced_type = 'multipart/form-data; boundary="test boundary"';
    my $spaced_body = mp_body('test boundary', ['doc', 'a.txt', 'text/plain', 'hi']);
    is req($spaced_type, $spaced_body)->headers->content_type_parameters->{boundary},
        'test boundary', 'shared reader extracts a quoted boundary with spaces';
    like dies { req($spaced_type, $spaced_body)->multipart_stream }, qr/not a valid boundary value/,
        'underlying parser rejects spaces in streaming boundary';
    like dies { req($spaced_type, $spaced_body)->uploads->get }, qr/not a valid boundary value/,
        'underlying parser rejects spaces in buffered boundary';

    for my $missing (
        'multipart/form-data',
        'multipart/form-data; boundary=""',
    ) {
        like dies { req($missing, $body)->multipart_stream }, qr/No boundary found/, "streaming rejects $missing";
        like dies { req($missing, $body)->uploads->get }, qr/No boundary found/, "buffered rejects $missing";
    }
    for my $invalid (
        'multipart/form-data; boundary=BOUND; BOUNDARY=other',
        'multipart/form-data; boundary="BOUND" junk',
    ) {
        is req($invalid, $body)->headers->content_type_parameters, undef,
            "shared reader rejects $invalid as a whole";
        like dies { req($invalid, $body)->multipart_stream }, qr/requires a multipart/i,
            "streaming rejects $invalid";
        is [req($invalid, $body)->uploads->get->keys], [],
            "buffered entry point does not parse malformed $invalid";
    }
};

done_testing;
