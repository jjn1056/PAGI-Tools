use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use File::Temp qw(tempfile);
use PAGI::Response;

# A HEAD response must carry GET's headers (including Content-Length) but an
# empty body. $res->head(1) puts respond() into head mode: it emits
# http.response.start with the normal headers, then a single empty
# http.response.body, skipping the real body/file/stream.

sub recorder { my @e; my $s = sub { push @e, $_[0]; Future->done }; return ($s, \@e) }
sub hdrs { my $e = shift; map { lc($_->[0]) => $_->[1] } @{ $e->{headers} // [] } }

subtest 'plain body: content-length kept, body emptied' => sub {
    my ($send, $sent) = recorder();
    PAGI::Response->new->text('Hello World!')->head(1)->respond($send)->get;   # 12 bytes

    is $sent->[0]{type}, 'http.response.start', 'start emitted';
    my %h = hdrs($sent->[0]);
    is $h{'content-length'}, 12, 'content-length reflects the would-be GET body';
    is $sent->[1]{type}, 'http.response.body', 'body event emitted';
    is $sent->[1]{body}, '', 'body suppressed';
    is $sent->[1]{more}, 0, 'response completed';
    is scalar(@$sent), 2, 'exactly start + one empty body';
};

subtest 'file body: headers kept, file not streamed' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    print {$fh} 'file-payload-bytes'; close $fh;   # 18 bytes

    my ($send, $sent) = recorder();
    PAGI::Response->new->send_file($path)->head(1)->respond($send)->get;

    is $sent->[0]{type}, 'http.response.start', 'start emitted';
    my %h = hdrs($sent->[0]);
    is $h{'content-length'}, 18, 'content-length from the file is preserved';
    is $sent->[1]{body}, '', 'empty body, not a file event';
    ok !exists $sent->[1]{file}, 'no file body event in head mode';
    is scalar(@$sent), 2, 'exactly start + one empty body';
};

subtest 'streaming body: stream callback does not run' => sub {
    my $ran = 0;
    my ($send, $sent) = recorder();
    my $res = PAGI::Response->new->stream(async sub {
        my ($w) = @_;
        $ran = 1;
        await $w->write('chunk');
    })->head(1);
    $res->respond($send)->get;

    is $sent->[0]{type}, 'http.response.start', 'start emitted';
    ok !$ran, 'stream producer is not invoked for a HEAD request';
    is $sent->[1]{body}, '', 'empty body';
    is scalar(@$sent), 2, 'exactly start + one empty body';
};

subtest 'is_head reflects the flag' => sub {
    ok(!PAGI::Response->new->is_head, 'false by default');
    ok(PAGI::Response->new->head(1)->is_head, 'true once set');
};

done_testing;
