#!/usr/bin/env perl
use strict;
use warnings;

use Test2::V0;
use Future;
use Hash::MultiValue;
use File::Temp qw(tempdir);
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Request;

sub events_receive {
    my (@events) = @_;
    my $calls = 0;
    my $receive = sub {
        ++$calls;
        die 'over-read' unless @events;
        return Future->done(shift @events);
    };
    return ($receive, sub { return $calls }, sub { return scalar @events });
}

sub request_for {
    my ($protocol, $events, %scope) = @_;
    my ($receive, $calls, $remaining) = events_receive(@$events);
    my $request = PAGI::Request->new({
        type    => $protocol,
        method  => 'POST',
        headers => [],
        %scope,
    }, $receive);
    return ($request, $calls, $remaining);
}

sub event_type {
    my ($protocol, $suffix) = @_;
    return "$protocol.$suffix";
}

sub build_multipart {
    my ($boundary, @parts) = @_;
    my $body = '';
    for my $part (@parts) {
        $body .= "--$boundary\r\n";
        $body .= "Content-Disposition: form-data; name=\"$part->{name}\"";
        $body .= "; filename=\"$part->{filename}\"" if defined $part->{filename};
        $body .= "\r\n";
        $body .= "Content-Type: $part->{content_type}\r\n" if $part->{content_type};
        $body .= "\r\n$part->{data}\r\n";
    }
    return $body . "--$boundary--\r\n";
}

subtest 'constructor accepts request-bearing protocols without receiving' => sub {
    for my $case (
        ['http',      'https'],
        ['websocket', 'ws'],
        ['websocket', 'wss'],
        ['sse',       'https'],
    ) {
        my ($type, $scheme) = @$case;
        my $scope = { type => $type, scheme => $scheme, path => '/native', headers => [] };
        my $request = PAGI::Request->new($scope, sub { die 'construction must not receive' });
        is(refaddr($request->scope), refaddr($scope), "$type keeps exact scope");
        is($request->scheme, $scheme, "$type keeps native $scheme scheme");
        is($request->method, undef, "$type does not fabricate an absent method");
    }

    for my $type ('lifespan', 'example.custom') {
        like dies {
            PAGI::Request->new({ type => $type }, sub { die 'must not receive' });
        }, qr/requires HTTP, WebSocket, or SSE scope.*\Q$type\E/i,
            "rejects $type scope";
    }
};

subtest 'HTTP and SSE buffered readers consume their native event families' => sub {
    for my $protocol ('http', 'sse') {
        my ($request, $calls, $remaining) = request_for($protocol, [
            { type => event_type($protocol, 'request'), body => '{"job":', more => 1 },
            { type => event_type($protocol, 'request'), body => '42}', more => 0 },
        ], headers => [['content-type', 'application/json']]);

        is($request->json->get, { job => 42 }, "$protocol JSON reads native chunks");
        is($calls->(), 2, "$protocol consumes exactly two chunks");
        is($remaining->(), 0, "$protocol leaves no supplied chunk unread");
        is($request->body->get, '{"job":42}', "$protocol buffered body can be reread");
        is($calls->(), 2, "$protocol cached reread does not receive");
    }

    for my $protocol ('http', 'sse') {
        my ($request) = request_for($protocol, [
            { type => event_type($protocol, 'request'), body => 'name=Jane+Doe&role=ops', more => 0 },
        ], headers => [['content-type', 'application/x-www-form-urlencoded']]);
        my $form = $request->form_params->get;
        is($form->get('name'), 'Jane Doe', "$protocol URL-encoded body is parsed");
        is($form->get('role'), 'ops', "$protocol second form value is parsed");
    }
};

subtest 'HTTP and SSE preserve body EOF, disconnect, and family rules' => sub {
    for my $protocol ('http', 'sse') {
        my ($empty) = request_for($protocol, [
            { type => event_type($protocol, 'request'), body => '', more => 0 },
        ]);
        is($empty->body->get, '', "$protocol empty final event is an empty body");

        my ($disconnected) = request_for($protocol, [
            { type => event_type($protocol, 'request'), body => 'partial', more => 1 },
            { type => event_type($protocol, 'disconnect') },
        ]);
        like dies { $disconnected->body->get }, qr/incomplete.*disconnected mid-body/i,
            "$protocol mid-body disconnect is truncation";

        my $other = $protocol eq 'http' ? 'sse' : 'http';
        my ($wrong) = request_for($protocol, [
            { type => event_type($other, 'request'), body => 'wrong', more => 0 },
        ]);
        like dies { $wrong->body->get },
            qr/unexpected request-body event '\Q$other.request\E' on \Q$protocol\E scope/,
            "$protocol rejects the other protocol's body event";

        my ($malformed) = request_for($protocol, ['not-a-hash']);
        like dies { $malformed->body->get }, qr/invalid request-body event/,
            "$protocol rejects malformed events";
    }
};

subtest 'HTTP and SSE body streams keep native events and existing limits' => sub {
    for my $protocol ('http', 'sse') {
        my ($request) = request_for($protocol, [
            { type => event_type($protocol, 'request'), body => "caf\xc3", more => 1 },
            { type => event_type($protocol, 'request'), body => "\xa9", more => 0 },
        ]);
        my $stream = $request->body_stream(decode => 'UTF-8');
        is($stream->next_chunk->get, 'caf', "$protocol stream buffers split UTF-8");
        is($stream->next_chunk->get, "é", "$protocol stream completes split UTF-8");

        my ($limited) = request_for($protocol, [
            { type => event_type($protocol, 'request'), body => '123456', more => 0 },
        ]);
        like dies { $limited->body_stream(max_bytes => 5)->next_chunk->get },
            qr/max_bytes exceeded/, "$protocol stream enforces size limit";

        my $other = $protocol eq 'http' ? 'sse' : 'http';
        my ($wrong) = request_for($protocol, [
            { type => event_type($other, 'request'), body => 'wrong', more => 0 },
        ]);
        like dies { $wrong->body_stream->next_chunk->get },
            qr/unexpected request-body event/, "$protocol stream rejects wrong event family";

        my ($stream_first) = request_for($protocol, []);
        $stream_first->body_stream;
        like dies { $stream_first->body->get }, qr/streaming already started/i,
            "$protocol streaming excludes buffered reads";

        my ($buffer_first) = request_for($protocol, [
            { type => event_type($protocol, 'request'), body => 'done', more => 0 },
        ]);
        is($buffer_first->body->get, 'done', "$protocol buffered read completes");
        like dies { $buffer_first->body_stream }, qr/already consumed|streaming not available/i,
            "$protocol buffered reads exclude streaming";
    }
};

subtest 'HTTP and SSE buffered multipart parse fields and uploads' => sub {
    my $boundary = 'NativeBufferedBoundary';
    my $body = build_multipart($boundary,
        { name => 'title', data => 'native input' },
        { name => 'doc', filename => 'native.txt', content_type => 'text/plain', data => 'file bytes' },
    );

    for my $protocol ('http', 'sse') {
        my ($request) = request_for($protocol, [
            { type => event_type($protocol, 'request'), body => substr($body, 0, 31), more => 1 },
            { type => event_type($protocol, 'request'), body => substr($body, 31), more => 0 },
        ], headers => [['content-type', "multipart/form-data; boundary=$boundary"]]);

        my $form = $request->form_params->get;
        is($form->get('title'), 'native input', "$protocol multipart field parsed");
        my $upload = $request->upload('doc')->get;
        is($upload->filename, 'native.txt', "$protocol multipart upload metadata parsed");
        is($upload->slurp, 'file bytes', "$protocol multipart upload bytes parsed");
    }
};

subtest 'HTTP and SSE buffered multipart clean spooled files after interruption' => sub {
    my $boundary = 'InterruptedBoundary';
    my $body = build_multipart($boundary,
        { name => 'doc', filename => 'large.bin', content_type => 'application/octet-stream', data => ('x' x 200) },
    );
    my $partial = substr($body, 0, index($body, 'x' x 20) + 100);

    for my $protocol ('http', 'sse') {
        my $dir = tempdir(CLEANUP => 1);
        my ($request) = request_for($protocol, [
            { type => event_type($protocol, 'request'), body => $partial, more => 1 },
            { type => event_type($protocol, 'disconnect') },
        ], headers => [['content-type', "multipart/form-data; boundary=$boundary"]]);

        like dies {
            $request->form_params(spool_threshold => 8, temp_dir => $dir)->get;
        }, qr/incomplete.*disconnected mid-body/i,
            "$protocol interrupted multipart fails";
        opendir my $dh, $dir or die "Cannot inspect $dir: $!";
        my @left = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        is(\@left, [], "$protocol interrupted multipart removes spooled files");
    }
};

subtest 'HTTP and SSE multipart streams use native events' => sub {
    my $boundary = 'NativeStreamBoundary';
    my $body = build_multipart($boundary,
        { name => 'doc', filename => 'stream.txt', content_type => 'text/plain', data => 'streamed' },
    );

    for my $protocol ('http', 'sse') {
        my ($request) = request_for($protocol, [
            { type => event_type($protocol, 'request'), body => $body, more => 0 },
        ], headers => [['content-type', "multipart/form-data; boundary=$boundary"]]);
        my $stream = $request->multipart_stream;
        my $part = $stream->next->get;
        is($part->filename, 'stream.txt', "$protocol streaming multipart metadata parsed");
        is($part->value->get, 'streamed', "$protocol streaming multipart bytes parsed");

        my $other = $protocol eq 'http' ? 'sse' : 'http';
        my ($wrong) = request_for($protocol, [
            { type => event_type($other, 'request'), body => $body, more => 0 },
        ], headers => [['content-type', "multipart/form-data; boundary=$boundary"]]);
        like dies { $wrong->multipart_stream->next->get }, qr/unexpected request-body event/,
            "$protocol streaming multipart rejects wrong event family";
    }
};

subtest 'HTTP and SSE buffered multipart reject wrong event families' => sub {
    my $boundary = 'WrongBufferedBoundary';
    my $body = build_multipart($boundary, { name => 'title', data => 'wrong' });
    for my $protocol ('http', 'sse') {
        my $other = $protocol eq 'http' ? 'sse' : 'http';
        my ($request) = request_for($protocol, [
            { type => event_type($other, 'request'), body => $body, more => 0 },
        ], headers => [['content-type', "multipart/form-data; boundary=$boundary"]]);
        like dies { $request->form_params->get }, qr/unexpected request-body event/,
            "$protocol buffered multipart rejects wrong event family";
    }
};

subtest 'WebSocket body APIs reject before receive, caches, or flags' => sub {
    my @methods = (
        ['body',             sub { $_[0]->body->get }],
        ['text',             sub { $_[0]->text->get }],
        ['json',             sub { $_[0]->json->get }],
        ['form_params',      sub { $_[0]->form_params->get }],
        ['form',             sub { local $SIG{__WARN__} = sub {}; $_[0]->form->get }],
        ['form_param',       sub { $_[0]->form_param('name')->get }],
        ['raw_form_params',  sub { $_[0]->raw_form_params->get }],
        ['raw_form',         sub { local $SIG{__WARN__} = sub {}; $_[0]->raw_form->get }],
        ['raw_form_param',   sub { $_[0]->raw_form_param('name')->get }],
        ['uploads',          sub { $_[0]->uploads->get }],
        ['upload',           sub { $_[0]->upload('file')->get }],
        ['upload_all',       sub { $_[0]->upload_all('file')->get }],
        ['body_stream',      sub { $_[0]->body_stream }],
        ['multipart_stream', sub { $_[0]->multipart_stream }],
    );

    for my $method (@methods) {
        my ($name, $invoke) = @$method;
        my $calls = 0;
        my $form = Hash::MultiValue->new(name => 'cached');
        my $uploads = Hash::MultiValue->new(file => 'cached');
        my $scope = {
            type => 'websocket',
            'pagi.request.body'    => 'cached body',
            'pagi.request.body.read' => 1,
            'pagi.request.body.truncated' => 1,
            'pagi.request.body.stream.created' => 1,
            'pagi.request.form'    => $form,
            'pagi.request.uploads' => $uploads,
        };
        my $request = PAGI::Request->new($scope, sub {
            ++$calls;
            return Future->done({ type => 'websocket.receive', bytes => 'bad' });
        });
        my %before = map { $_ => $scope->{$_} }
            qw(pagi.request.body.read pagi.request.body.truncated pagi.request.body.stream.created);

        like dies { $invoke->($request) }, qr/body input requires HTTP or SSE scope/,
            "$name rejects WebSocket body input";
        is($calls, 0, "$name does not receive");
        is($scope->{'pagi.request.body'}, 'cached body', "$name leaves body cache unchanged");
        is(refaddr($scope->{'pagi.request.form'}), refaddr($form), "$name leaves form cache unchanged");
        is(refaddr($scope->{'pagi.request.uploads'}), refaddr($uploads), "$name leaves upload cache unchanged");
        for my $flag (keys %before) {
            is($scope->{$flag}, $before{$flag}, "$name leaves $flag unchanged");
        }
    }
};

done_testing;
