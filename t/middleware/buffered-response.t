#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Middleware::BufferedResponse qw(buffer_whole_response);

sub http_scope {
    return { type => 'http', method => 'GET', path => '/x', scheme => 'http',
             http_version => '1.1', headers => [] };
}

sub drive {
    my ($wrapped, $scope) = @_;
    my @sent;
    Future->wrap($wrapped->($scope // http_scope(), sub { Future->done },
        sub { push @sent, $_[0]; Future->done }))->get;
    return @sent;
}

subtest 'a complete response reaches transform and is rewritten' => sub {
    my $called = 0;
    my $app = sub {
        my ($s, $r, $send) = @_;
        return (async sub {
            await $send->({ type => 'http.response.start', status => 200,
                            headers => [['content-type', 'text/plain']] });
            await $send->({ type => 'http.response.body', body => 'hello',
                            more => 0 });
            return;
        })->();
    };

    my @sent = drive(buffer_whole_response($app,
        engage    => sub { 1 },
        transform => sub {
            my ($status, $headers, $body) = @_;
            $called++;
            push @$headers, ['X-Len', length $body];
            return ($status, $headers, uc $body);
        },
    ));

    is($called, 1, 'transform ran once');
    is(scalar(@sent), 2, 'start and one body event');
    is($sent[1]{body}, 'HELLO', 'transformed body is emitted');
    is($sent[1]{more}, 0, 'terminal event preserved');
    my ($len) = grep { $_->[0] eq 'X-Len' } @{ $sent[0]{headers} };
    is($len->[1], 5, 'header added by transform is present');
};

subtest 'an incomplete response never reaches transform' => sub {
    my $called = 0;
    my $app = sub {
        my ($s, $r, $send) = @_;
        return (async sub {
            await $send->({ type => 'http.response.start', status => 200,
                            headers => [['content-type', 'text/plain']] });
            return;   # no body event at all
        })->();
    };

    my @sent = drive(buffer_whole_response($app,
        engage    => sub { 1 },
        transform => sub { $called++; return @_ },
    ));

    is($called, 0, 'transform never ran -- metadata cannot be computed');
    is(scalar(@sent), 1, 'only the withheld start was emitted');
    is($sent[0]{type}, 'http.response.start', 'and it is the start');
    is(scalar(grep { $_->{type} eq 'http.response.body' } @sent), 0,
        'no body event is fabricated');
};

subtest 'a partial stream emits what arrived, with no terminal event' => sub {
    my $called = 0;
    my $app = sub {
        my ($s, $r, $send) = @_;
        return (async sub {
            await $send->({ type => 'http.response.start', status => 200,
                            headers => [] });
            await $send->({ type => 'http.response.body', body => 'part',
                            more => 1 });
            return;
        })->();
    };

    my @sent = drive(buffer_whole_response($app,
        engage    => sub { 1 },
        transform => sub { $called++; return @_ },
    ));

    is($called, 0, 'transform never ran');
    is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @sent), 0,
        'no terminal event is fabricated');
    is(scalar(grep { $_->{type} eq 'http.response.start' } @sent), 1,
        'the start still reaches the wire');
    my ($chunk) = grep { $_->{type} eq 'http.response.body' } @sent;
    is($chunk->{more}, 1, 'the forwarded chunk keeps more => 1');
};

subtest 'an app that starts nothing produces nothing' => sub {
    my $app = sub { my ($s, $r, $send) = @_; return Future->done };
    my @sent = drive(buffer_whole_response($app,
        engage => sub { 1 }, transform => sub { return @_ }));
    is(scalar(@sent), 0, 'nothing withheld, nothing emitted');
};

subtest 'engage false passes everything through untouched' => sub {
    my $called = 0;
    my $app = sub {
        my ($s, $r, $send) = @_;
        return (async sub {
            await $send->({ type => 'http.response.start', status => 200,
                            headers => [] });
            await $send->({ type => 'http.response.body', body => 'x',
                            more => 0 });
            return;
        })->();
    };
    my @sent = drive(buffer_whole_response($app,
        engage => sub { 0 }, transform => sub { $called++; return @_ }));
    is($called, 0, 'transform never ran');
    is(scalar(@sent), 2, 'events passed through');
    is($sent[1]{body}, 'x', 'body untouched');
};

subtest 'transform does not see the application headers arrayref' => sub {
    # The helper hands transform its own copy, so a middleware that appends
    # cannot corrupt an arrayref the application built once and reuses.
    my $shared = [['content-type', 'text/plain']];
    my $app = sub {
        my ($s, $r, $send) = @_;
        return (async sub {
            await $send->({ type => 'http.response.start', status => 200,
                            headers => $shared });
            await $send->({ type => 'http.response.body', body => 'x',
                            more => 0 });
            return;
        })->();
    };
    drive(buffer_whole_response($app,
        engage    => sub { 1 },
        transform => sub {
            my ($status, $headers, $body) = @_;
            push @$headers, ['X-Added', 1];
            return ($status, $headers, $body);
        },
    ));
    is(scalar(@$shared), 1,
        "the application's own headers arrayref was not appended to");
};

subtest 'the terminal event keeps its native shape' => sub {
    # The application omitted `more`, which defaults to 0. The helper must
    # re-emit its event with the transformed body substituted, not construct
    # a fresh one carrying an explicit more => 0: semantically identical, but
    # a middleware should change what it needs to and nothing else.
    my $app = sub {
        my ($s, $r, $send) = @_;
        return (async sub {
            await $send->({ type => 'http.response.start', status => 200,
                            headers => [] });
            await $send->({ type => 'http.response.body', body => 'native' });
            return;
        })->();
    };

    my @sent = drive(buffer_whole_response($app,
        engage    => sub { 1 },
        transform => sub { my ($st, $h, $b) = @_; return ($st, $h, uc $b) }));

    my ($body) = grep { $_->{type} eq 'http.response.body' } @sent;
    is($body, { type => 'http.response.body', body => 'NATIVE' },
        'the event is the application\'s, with only the body changed');
};

subtest 'an opaque body is forwarded and transform is skipped' => sub {
    my $called = 0;
    my $app = sub {
        my ($s, $r, $send) = @_;
        return (async sub {
            await $send->({ type => 'http.response.start', status => 200,
                            headers => [] });
            await $send->({ type => 'http.response.body',
                            file => '/nonexistent/path' });
            return;
        })->();
    };
    my @sent = drive(buffer_whole_response($app,
        engage => sub { 1 }, transform => sub { $called++; return @_ }));
    is($called, 0, 'transform never ran -- there is no body string to transform');
    is(scalar(grep { $_->{type} eq 'http.response.start' } @sent), 1,
        'the start was flushed');
    ok(scalar(grep { exists $_->{file} } @sent) >= 1,
        'the opaque event was forwarded verbatim');
};

subtest 'non-http scopes are passed through' => sub {
    my $ran = 0;
    my $app = sub { my ($s, $r, $send) = @_; $ran++; return Future->done };
    my $wrapped = buffer_whole_response($app,
        engage => sub { 1 }, transform => sub { return @_ });
    Future->wrap($wrapped->({ type => 'websocket' }, sub { Future->done },
        sub { Future->done }))->get;
    is($ran, 1, 'inner app ran');
};

done_testing;
