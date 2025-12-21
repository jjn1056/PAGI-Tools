#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Request::MultiPartHandler;

# Helper to build multipart body
sub build_multipart {
    my ($boundary, @parts) = @_;
    my $body = '';
    for my $part (@parts) {
        $body .= "--$boundary\r\n";
        $body .= "Content-Disposition: form-data; name=\"$part->{name}\"";
        if ($part->{filename}) {
            $body .= "; filename=\"$part->{filename}\"";
        }
        $body .= "\r\n";
        if ($part->{content_type}) {
            $body .= "Content-Type: $part->{content_type}\r\n";
        }
        $body .= "\r\n";
        $body .= $part->{data};
        $body .= "\r\n";
    }
    $body .= "--$boundary--\r\n";
    return $body;
}

sub mock_receive {
    my ($body) = @_;
    my $sent = 0;
    return async sub {
        if (!$sent) {
            $sent = 1;
            return { type => 'http.request', body => $body, more => 0 };
        }
        return { type => 'http.disconnect' };
    };
}

subtest 'parse simple form fields' => sub {
    my $boundary = '----WebKitFormBoundary7MA4YWxkTrZu0gW';
    my $body = build_multipart($boundary,
        { name => 'title', data => 'Hello World' },
        { name => 'count', data => '42' },
    );

    my $receive = mock_receive($body);
    my $handler = PAGI::Request::MultiPartHandler->new(
        boundary => $boundary,
        receive  => $receive,
    );

    my ($form, $uploads) = (async sub { await $handler->parse })->()->get;

    isa_ok($form, ['Hash::MultiValue'], 'form is Hash::MultiValue');
    is($form->get('title'), 'Hello World', 'title field');
    is($form->get('count'), '42', 'count field');
    is([$uploads->keys], [], 'no uploads');
};

subtest 'parse file upload' => sub {
    my $boundary = '----TestBoundary';
    my $body = build_multipart($boundary,
        { name => 'name', data => 'John' },
        {
            name         => 'avatar',
            filename     => 'photo.jpg',
            content_type => 'image/jpeg',
            data         => 'fake image bytes',
        },
    );

    my $receive = mock_receive($body);
    my $handler = PAGI::Request::MultiPartHandler->new(
        boundary => $boundary,
        receive  => $receive,
    );

    my ($form, $uploads) = (async sub { await $handler->parse })->()->get;

    is($form->get('name'), 'John', 'form field');

    my $upload = $uploads->get('avatar');
    isa_ok($upload, ['PAGI::Request::Upload'], 'upload object');
    is($upload->filename, 'photo.jpg', 'filename');
    is($upload->content_type, 'image/jpeg', 'content_type');
    is($upload->slurp, 'fake image bytes', 'content');
};

subtest 'parse multiple files same field' => sub {
    my $boundary = '----Multi';
    my $body = build_multipart($boundary,
        { name => 'files', filename => 'a.txt', content_type => 'text/plain', data => 'AAA' },
        { name => 'files', filename => 'b.txt', content_type => 'text/plain', data => 'BBB' },
    );

    my $receive = mock_receive($body);
    my $handler = PAGI::Request::MultiPartHandler->new(
        boundary => $boundary,
        receive  => $receive,
    );

    my ($form, $uploads) = (async sub { await $handler->parse })->()->get;

    my @files = $uploads->get_all('files');
    is(scalar(@files), 2, 'two files');
    is($files[0]->filename, 'a.txt', 'first file');
    is($files[1]->filename, 'b.txt', 'second file');
};

done_testing;
