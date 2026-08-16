#!/usr/bin/env perl

use strict;
use warnings;
use bytes ();
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use Errno qw(EIO);
use File::Spec;
use File::Temp qw(tempdir);
use Future;
use JSON::MaybeXS ();
use Test2::V0;

use lib 'lib';
use PAGI::App::Directory;
use PAGI::App::File;
use PAGI::Test::Client;

{
    package Local::CountingDirectory;
    use parent 'PAGI::App::Directory';

    sub locate {
        my ($self, @args) = @_;
        $self->{_test_locate_calls}++;
        return $self->SUPER::locate(@args);
    }

    sub serve {
        my ($self, @args) = @_;
        $self->{_test_serve_calls}++;
        return $self->SUPER::serve(@args);
    }

    sub reset_calls {
        my ($self) = @_;
        $self->{_test_locate_calls} = 0;
        $self->{_test_serve_calls} = 0;
        return;
    }

    sub locate_calls { return $_[0]->{_test_locate_calls} // 0 }
    sub serve_calls  { return $_[0]->{_test_serve_calls} // 0 }
}

{
    package Local::FailingDirectory;
    use parent 'PAGI::App::Directory';

    sub _open_directory {
        $! = Errno::EIO();
        return;
    }
}

sub write_file {
    my ($path, $contents) = @_;
    open my $fh, '>', $path or die "Cannot create $path: $!";
    print {$fh} $contents;
    close $fh or die "Cannot close $path: $!";
    return;
}

sub native_scope {
    my ($method, $path, $headers) = @_;
    return {
        type => 'http', method => $method, path => $path,
        raw_path => $path, root_path => '', headers => $headers // [],
        path_params => {},
    };
}

sub run_native {
    my ($component, $method, $path, $headers) = @_;
    my @events;
    $component->to_app->(
        native_scope($method, $path, $headers),
        sub { return Future->done({ type => 'http.disconnect' }) },
        sub { push @events, $_[0]; return Future->done },
    )->get;
    return \@events;
}

sub event_header {
    my ($event, $name) = @_;
    for my $header (@{$event->{headers} // []}) {
        return $header->[1] if lc($header->[0]) eq lc($name);
    }
    return;
}

sub assert_listing_head_parity {
    my ($component, $path, $headers, $label) = @_;
    my $get = run_native($component, 'GET', $path, $headers);
    my $head = run_native($component, 'HEAD', $path, $headers);

    is($head->[0], $get->[0], "$label HEAD preserves GET status and headers");
    is(event_header($get->[0], 'content-length'),
        bytes::length($get->[1]{body}),
        "$label Content-Length counts emitted bytes");
    is($head->[1], {
        type => 'http.response.body', body => '', more => 0,
    }, "$label HEAD emits one terminal empty body event");
    is(scalar(@$head), 2, "$label HEAD emits no listing bytes");
    return;
}

subtest 'Directory adds only eligible listings over File request handling' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $listing = File::Spec->catdir($root, 'listing');
    mkdir $listing or die "Cannot create $listing: $!";
    write_file(File::Spec->catfile($listing, 'listed.txt'), 'listed');
    write_file(File::Spec->catfile($root, 'plain.txt'), 'plain');

    my $component = Local::CountingDirectory->new(root => $root);
    my $client = PAGI::Test::Client->new(
        app => $component, raise_app_exceptions => 1,
    );

    $component->reset_calls;
    my $post = $client->post('/listing');
    is($post->status, 405,
        'unsupported method cannot render a listing');
    is($post->header('Allow'), 'GET, HEAD',
        'unsupported method retains the exact File Allow field');
    is($component->locate_calls, 0,
        'unsupported method is handled before location');
    is($component->serve_calls, 0,
        'unsupported method remains parent application policy');

    $component->reset_calls;
    my $listing_response = $client->get('/listing');
    is($listing_response->status, 200, 'directory Result renders a listing');
    like($listing_response->text, qr/listed\.txt/,
        'listing contains the eligible entry');
    is($component->locate_calls, 1,
        'directory request locates exactly once');
    is($component->serve_calls, 0,
        'directory Result is the only Result intercepted before serve');

    $component->reset_calls;
    my $file_response = $client->get('/plain.txt');
    is($file_response->status, 200, 'file Result keeps File response handling');
    is($file_response->text, 'plain', 'delegated file body is unchanged');
    is($component->locate_calls, 1, 'file request locates exactly once');
    is($component->serve_calls, 1, 'file Result delegates to inherited serve');

    $component->reset_calls;
    my $missing = $client->get('/missing.txt', headers => {
        Accept => 'application/problem+json',
    });
    is($missing->status, 404,
        'missing directory candidate uses File not-found');
    is($missing->json, {
        type   => 'about:blank',
        title  => 'Not Found',
        status => 404,
        detail => 'The requested resource was not found.',
    }, 'missing Result uses the stock safe problem body');
    unlike($missing->content, qr/missing\.txt|\Q$root\E/,
        'missing response does not disclose request or filesystem paths');
    is($component->locate_calls, 1, 'missing request locates exactly once');
    is($component->serve_calls, 1,
        'missing Result delegates to inherited serve');

    $component->reset_calls;
    my $forbidden = $client->get('/../outside');
    is($forbidden->status, 403, 'unsafe traversal remains forbidden');
    is($component->locate_calls, 1,
        'forbidden request reaches the one locator');
    is($component->serve_calls, 1,
        'forbidden Result delegates to inherited serve');

    for my $case (
        [missing => { method => 'GET', path => '/', headers => [] },
            qr/scope type.*required/i],
        [extension => {
            type => 'example.custom', method => 'GET', path => '/', headers => [],
        }, qr/requires HTTP scope.*example\.custom/i],
    ) {
        my ($label, $scope, $error) = @$case;
        my @events;
        $component->reset_calls;
        like(dies {
            $component->to_app->(
                $scope,
                sub { return Future->done({ type => 'http.disconnect' }) },
                sub { push @events, $_[0]; return Future->done },
            )->get;
        }, $error, "rejects $label scope type");
        is(\@events, [], "$label scope is rejected before response events");
        is($component->locate_calls, 0,
            "$label scope is rejected before location");
    }
};

subtest 'HTML and JSON listings preserve GET headers and suppress HEAD bytes' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $listing = File::Spec->catdir($root, 'listing');
    mkdir $listing or die "Cannot create $listing: $!";
    write_file(File::Spec->catfile($listing, 'sample.txt'), 'sample');

    my $component = PAGI::App::Directory->new(root => $root);
    assert_listing_head_parity($component, '/listing', [], 'HTML listing');
    assert_listing_head_parity(
        $component, '/listing', [['accept', 'application/json']],
        'JSON listing',
    );
};

subtest 'allow_hidden is shared by listing and direct File retrieval' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $listing = File::Spec->catdir($root, 'listing');
    mkdir $listing or die "Cannot create $listing: $!";
    write_file(File::Spec->catfile($listing, 'visible.txt'), 'visible');
    write_file(File::Spec->catfile($listing, '.listed'), 'listed hidden');
    write_file(File::Spec->catfile($root, '.direct'), 'direct hidden');

    my $default = PAGI::Test::Client->new(
        app => PAGI::App::Directory->new(root => $root),
        raise_app_exceptions => 1,
    );
    unlike($default->get('/listing')->text, qr/\.listed/,
        'hidden listing entry is omitted by default');
    is($default->get('/.direct')->status, 403,
        'hidden direct retrieval is forbidden by default');

    my $removed_legacy_option = PAGI::Test::Client->new(
        app => PAGI::App::Directory->new(root => $root, show_hidden => 1),
        raise_app_exceptions => 1,
    );
    my $legacy_listing = $removed_legacy_option->get('/listing')->text;
    unlike($legacy_listing, qr/\.listed/,
        'removed show_hidden option does not split listing policy');
    my @legacy_parent_links = $legacy_listing =~ /href="\.\.\/"/g;
    is(scalar(@legacy_parent_links), 1,
        'removed show_hidden cannot expose dot directory entries');

    my $allowed = PAGI::Test::Client->new(
        app => PAGI::App::Directory->new(root => $root, allow_hidden => 1),
        raise_app_exceptions => 1,
    );
    my $allowed_listing = $allowed->get('/listing')->text;
    like($allowed_listing, qr/\.listed/,
        'allow_hidden includes a hidden listing entry');
    my @allowed_parent_links = $allowed_listing =~ /href="\.\.\/"/g;
    is(scalar(@allowed_parent_links), 1,
        'allow_hidden still renders exactly one explicit parent link');
    is($allowed->get('/.direct')->text, 'direct hidden',
        'allow_hidden permits direct inherited File retrieval');
};

subtest 'file and index responses retain File ETag, range, and file events' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $indexed = File::Spec->catdir($root, 'indexed');
    mkdir $indexed or die "Cannot create $indexed: $!";
    write_file(File::Spec->catfile($root, 'plain.txt'), '0123456789');
    write_file(File::Spec->catfile($indexed, 'index.html'), 'index-body');

    my $directory = PAGI::App::Directory->new(root => $root);
    my $file = PAGI::App::File->new(root => $root);
    my $directory_client = PAGI::Test::Client->new(
        app => $directory, raise_app_exceptions => 1,
    );
    my $file_client = PAGI::Test::Client->new(
        app => $file, raise_app_exceptions => 1,
    );

    for my $path ('/plain.txt', '/indexed') {
        my $directory_get = $directory_client->get($path);
        my $file_get = $file_client->get($path);
        is($directory_get->status, $file_get->status,
            "$path status matches File");
        is($directory_get->header('ETag'), $file_get->header('ETag'),
            "$path ETag matches File");
        is($directory_get->content, $file_get->content,
            "$path body matches File");

        my $directory_range = $directory_client->get($path, headers => {
            Range => 'bytes=1-3',
        });
        my $file_range = $file_client->get($path, headers => {
            Range => 'bytes=1-3',
        });
        is($directory_range->status, 206,
            "$path valid range remains partial content");
        is($directory_range->header('Content-Range'),
            $file_range->header('Content-Range'),
            "$path Content-Range matches File");
        is($directory_range->header('ETag'), $file_range->header('ETag'),
            "$path range ETag matches File");
        is($directory_range->content, $file_range->content,
            "$path range body matches File");

        my $directory_events = run_native($directory, 'GET', $path);
        my $file_events = run_native($file, 'GET', $path);
        is($directory_events, $file_events,
            "$path native file event matches File");

        my $head_events = run_native($directory, 'HEAD', $path);
        is($head_events->[0], $directory_events->[0],
            "$path HEAD preserves delegated GET status and headers");
        is($head_events->[1], {
            type => 'http.response.body', body => '', more => 0,
        }, "$path HEAD emits one terminal empty body event");
        is(scalar(@$head_events), 2,
            "$path HEAD emits no delegated file bytes");
    }

    my $events = run_native($directory, 'GET', '/plain.txt');
    is($events->[1]{file}, File::Spec->catfile($root, 'plain.txt'),
        'Directory leaves file opening to the server');
    ok(!exists $events->[1]{fh},
        'Directory does not introduce an opened filehandle');
};

subtest 'trusted outward symlink file delegates successfully' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $outside = tempdir(CLEANUP => 1);
    my $target = File::Spec->catfile($outside, 'outside.txt');
    my $link = File::Spec->catfile($root, 'trusted.txt');
    write_file($target, 'trusted target');

    unless (eval { symlink($target, $link) or die "$!"; 1 }) {
        my $reason = $@ || $! || 'symlink unavailable';
        plan skip_all => "cannot create symlink: $reason";
    }

    my $response = PAGI::Test::Client->new(
        app => PAGI::App::Directory->new(root => $root),
        raise_app_exceptions => 1,
    )->get('/trusted.txt');
    is($response->status, 200,
        'trusted outward symlink file is served');
    is($response->text, 'trusted target',
        'trusted outward symlink retains its target bytes');
};

subtest 'hostile names are escaped for HTML and encoded for URLs' => sub {
    is(PAGI::App::Directory::_html_escape('<script>'), '&lt;script&gt;',
        'escapes angle brackets');
    is(PAGI::App::Directory::_html_escape('"quoted"'),
        '&quot;quoted&quot;', 'escapes double quotes');
    is(PAGI::App::Directory::_html_escape("it's"), "it&#39;s",
        'escapes single quotes');
    is(PAGI::App::Directory::_html_escape('a&b'), 'a&amp;b',
        'escapes ampersand');
    is(PAGI::App::Directory::_html_escape(undef), '',
        'undefined HTML input is empty');
    is(PAGI::App::Directory::_url_encode('file with spaces.txt'),
        'file%20with%20spaces.txt', 'spaces are URL encoded');
    is(PAGI::App::Directory::_url_encode('file<script>.txt'),
        'file%3Cscript%3E.txt', 'angle brackets are URL encoded');
    is(PAGI::App::Directory::_url_encode(undef), '',
        'undefined URL input is empty');

    my $root = tempdir(CLEANUP => 1);
    my $hostile = q{<script onclick="x">&'.txt};
    my $path = File::Spec->catfile($root, $hostile);
    unless (eval { write_file($path, 'hostile'); 1 }) {
        my $reason = $@ || $! || 'hostile filename unavailable';
        plan skip_all => "cannot create hostile filename: $reason";
    }

    my $html = PAGI::Test::Client->new(
        app => PAGI::App::Directory->new(root => $root),
        raise_app_exceptions => 1,
    )->get('/')->text;
    unlike($html, qr/<script|onclick="x"/,
        'hostile filename is not emitted as active HTML');
    like($html, qr/\Q&lt;script onclick=&quot;x&quot;&gt;&amp;&#39;.txt\E/,
        'hostile display name is HTML escaped');
    like($html, qr/\Q%3Cscript%20onclick%3D%22x%22%3E%26%27.txt\E/,
        'hostile href is URL encoded');
};

subtest 'decoded non-ASCII listing values emit UTF-8 octets' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $name = "\x{2615}.txt";
    my $component = PAGI::App::Directory->new(root => $root);

    is(PAGI::App::Directory::_url_encode($name),
        '%E2%98%95.txt', 'Unicode href is encoded by UTF-8 bytes');

    my @path_events;
    $component->_send_listing(
        sub { push @path_events, $_[0]; return Future->done },
        native_scope('GET', '/', []), $root, "\x{2615}",
    )->get;
    ok(!utf8::is_utf8($path_events[1]{body}),
        'decoded listing path is normalized to output octets');
    like(decode(
        'UTF-8', $path_events[1]{body}, FB_CROAK | LEAVE_SRC,
    ), qr/\x{2615}/,
        'decoded listing path is encoded exactly once');
};

subtest 'non-ASCII filesystem names round-trip where supported' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $name = "\x{2615}.txt";
    my $name_bytes = encode('UTF-8', $name, FB_CROAK | LEAVE_SRC);
    my $created = eval {
        write_file(File::Spec->catfile($root, $name_bytes), 'coffee');
        1;
    };
    unless ($created) {
        my $reason = $@ || $! || 'UTF-8 byte filename unavailable';
        plan skip_all => "cannot create UTF-8 byte filename: $reason";
    }

    opendir my $dh, $root
        or plan skip_all => "cannot verify UTF-8 filename round trip: $!";
    my @names = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh
        or plan skip_all => "cannot close UTF-8 filename directory: $!";
    plan skip_all => 'filesystem does not round-trip UTF-8 byte filenames'
        unless @names == 1 && $names[0] eq $name_bytes;

    my $component = PAGI::App::Directory->new(root => $root);

    my $html_events = run_native($component, 'GET', '/');
    is(event_header($html_events->[0], 'content-type'),
        'text/html; charset=utf-8',
        'HTML listing declares its UTF-8 encoding');
    ok(!utf8::is_utf8($html_events->[1]{body}),
        'HTML listing body is an octet string');
    is(event_header($html_events->[0], 'content-length'),
        length($html_events->[1]{body}),
        'HTML Content-Length matches emitted UTF-8 octets');
    like(decode(
        'UTF-8', $html_events->[1]{body}, FB_CROAK | LEAVE_SRC,
    ), qr/\Q$name\E/,
        'HTML display name decodes exactly once');
    like($html_events->[1]{body}, qr/%E2%98%95\.txt/,
        'HTML href contains encoded UTF-8 bytes');

    my $json_events = run_native(
        $component, 'GET', '/', [['accept', 'application/json']],
    );
    ok(!utf8::is_utf8($json_events->[1]{body}),
        'JSON listing body is an octet string');
    is(event_header($json_events->[0], 'content-length'),
        length($json_events->[1]{body}),
        'JSON Content-Length matches emitted UTF-8 octets');
    is(JSON::MaybeXS::decode_json($json_events->[1]{body})->[0]{name},
        $name, 'JSON entry name decodes exactly once');
};

subtest 'listing permission failure uses Pages forbidden where supported' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $locked = File::Spec->catdir($root, 'locked');
    mkdir $locked or die "Cannot create $locked: $!";
    write_file(File::Spec->catfile($locked, 'private.txt'), 'private');

    chmod 0000, $locked or plan skip_all => "cannot remove permissions: $!";
    if (opendir my $probe, $locked) {
        closedir $probe;
        chmod 0700, $locked or die "Cannot restore $locked: $!";
        plan skip_all => 'current user can open a mode-0000 directory';
    }

    my ($permission_response, $permission_error);
    eval {
        $permission_response = PAGI::Test::Client->new(
            app => PAGI::App::Directory->new(root => $root, index => []),
            raise_app_exceptions => 1,
        )->get('/locked', headers => { Accept => 'application/problem+json' });
        1;
    } or $permission_error = $@;
    chmod 0700, $locked or die "Cannot restore $locked: $!";
    die $permission_error if defined($permission_error) && length($permission_error);

    is($permission_response->status, 403,
        'opendir permission failure uses Pages forbidden');
    is($permission_response->content_type, 'application/problem+json',
        'listing permission failure preserves Pages negotiation');

};

subtest 'unexpected listing open failure propagates' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $unexpected = Local::FailingDirectory->new(root => $root);
    like(dies { run_native($unexpected, 'GET', '/') },
        qr/Cannot open directory.*Input\/output error/i,
        'unexpected opendir failure propagates');
};

subtest 'listing send failures propagate asynchronously' => sub {
    my $root = tempdir(CLEANUP => 1);
    write_file(File::Spec->catfile($root, 'sample.txt'), 'sample');
    my $component = PAGI::App::Directory->new(root => $root);
    my $app = $component->to_app;
    my $calls = 0;

    like(dies {
        $app->(
            native_scope('GET', '/', []),
            sub { return Future->done({ type => 'http.disconnect' }) },
            sub {
                $calls++;
                return Future->fail('simulated listing send failure');
            },
        )->get;
    }, qr/simulated listing send failure/,
        'listing send failure is not swallowed');
    is($calls, 1, 'body send is not attempted after start send failure');

    my $body_calls = 0;
    like(dies {
        $app->(
            native_scope('GET', '/', []),
            sub { return Future->done({ type => 'http.disconnect' }) },
            sub {
                $body_calls++;
                return $body_calls == 1
                    ? Future->done
                    : Future->fail('simulated listing body failure');
            },
        )->get;
    }, qr/simulated listing body failure/,
        'listing body send failure is not swallowed');
    is($body_calls, 2, 'body send is awaited after response start');
};

done_testing;
