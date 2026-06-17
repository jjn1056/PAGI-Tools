use strict; use warnings;
use Test2::V0;
use Future;
use PAGI::Request::MultipartStream;

sub receiver {                              # receiver(@chunks) — last real chunk has more=0
    my @chunks = @_;
    return sub {
        my $c = shift @chunks;
        return Future->done(defined $c
            ? { type => 'http.request', body => $c, more => (@chunks ? 1 : 0) }
            : { type => 'http.disconnect' });
    };
}
sub mp_body {                               # build a multipart body from [name,filename,ct,data] rows
    my ($b, @rows) = @_;
    my $s = '';
    for my $r (@rows) {
        my ($name, $filename, $ct, $data) = @$r;
        my $cd = qq{form-data; name="$name"};
        $cd .= qq{; filename="$filename"} if defined $filename;
        $s .= "--$b\r\nContent-Disposition: $cd\r\n";
        $s .= "Content-Type: $ct\r\n" if defined $ct;
        $s .= "\r\n$data\r\n";
    }
    return $s . "--$b--\r\n";
}

my $b = 'BOUND';
my $body = mp_body($b, ['title',undef,undef,'Hello'], ['doc','a.txt','text/plain',"line1\nline2"]);

subtest 'yields a field then a file across split chunks' => sub {
    my $half = int(length($body)/2);
    my $s = PAGI::Request::MultipartStream->new(
        receive => receiver(substr($body,0,$half), substr($body,$half)), boundary => $b);
    my $p1 = $s->next->get;
    is $p1->type, 'field', 'first is a field';
    is $p1->name, 'title', 'field name';
    my $p2 = $s->next->get;
    is $p2->type, 'file', 'second is a file';
    is $p2->filename, 'a.txt', 'filename';
    is $p2->content_type, 'text/plain', 'content type';
    is $s->next->get, undef, 'undef at end';
};

subtest 'advancing past an unconsumed part auto-drains' => sub {
    my $s = PAGI::Request::MultipartStream->new(receive => receiver($body), boundary => $b);
    $s->next->get;                          # field, not consumed
    my $p2 = $s->next->get;
    ok $p2->is_file && $p2->filename eq 'a.txt', 'auto-drained to the file part';
};

done_testing;
