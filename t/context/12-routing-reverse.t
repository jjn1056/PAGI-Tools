#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Context;
use PAGI::Routing qw(route router sse websocket);
use PAGI::Routing::Resolver;

sub _resolver {
    my (@routes) = @_;
    return PAGI::Routing::Resolver->new(routes => \@routes);
}

sub _frame {
    my ($resolver) = @_;
    return {
        resolver => $resolver,
        mounts   => [],
        match    => undef,
    };
}

sub _context {
    my ($type, $resolver, %scope) = @_;
    return PAGI::Context->new({
        type           => $type,
        headers        => [['host', 'example.test']],
        scheme         => 'http',
        root_path      => '',
        'pagi.routing' => {
            version => 1,
            frames  => [_frame($resolver)],
        },
        %scope,
    }, sub { }, sub { });
}

subtest 'Context selects the last resolver from a valid routing frame stack' => sub {
    my $parent = _resolver(
        route('/parent/{id}' => sub { }, name => 'selected'),
    );
    my $child = _resolver(
        route('/child/{id}' => sub { }, name => 'selected'),
    );
    my $context = _context('http', $child,
        root_path => '/edge',
        'pagi.routing' => {
            version => 1,
            frames  => [_frame($parent), _frame($child)],
        },
    );

    is(
        $context->path_for('selected', { id => 7 }),
        '/edge/child/7',
        'the last frame supplies Context reverse paths',
    );
    is(
        $context->url_for('selected', { id => 7 }),
        'http://example.test/edge/child/7',
        'the last frame also supplies Context absolute URLs',
    );
};

subtest 'all built-in Context subclasses inherit routing reverse methods' => sub {
    my $resolver = _resolver(
        route('/page' => sub { }, name => 'page'),
    );

    for my $case (
        ['http',      'PAGI::Context::HTTP'],
        ['websocket', 'PAGI::Context::WebSocket'],
        ['sse',       'PAGI::Context::SSE'],
    ) {
        my ($type, $class) = @$case;
        my $context = _context($type, $resolver);
        isa_ok($context, $class);
        is($context->path_for('page'), '/page', "$class inherits path_for");
        is(
            $context->url_for('page'),
            'http://example.test/page',
            "$class inherits url_for",
        );
    }
};

subtest 'missing and malformed routing metadata fail at the Context boundary' => sub {
    my $resolver = _resolver(route('/page' => sub { }, name => 'page'));
    my @cases = (
        ['missing container', undef],
        ['foreign version', { version => 2, frames => [_frame($resolver)] }],
        ['frames are not an array', { version => 1, frames => {} }],
        ['frames are empty', { version => 1, frames => [] }],
        ['last frame is not a hash', { version => 1, frames => ['bad'] }],
        ['last frame lacks a resolver', {
            version => 1,
            frames  => [{ mounts => [], match => undef }],
        }],
        ['last frame has malformed mounts', {
            version => 1,
            frames  => [{ resolver => $resolver, mounts => {}, match => undef }],
        }],
        ['last frame has malformed match', {
            version => 1,
            frames  => [{ resolver => $resolver, mounts => [], match => [] }],
        }],
    );

    for my $case (@cases) {
        my ($label, $routing) = @$case;
        my %scope = (
            type    => 'http',
            headers => [['host', 'example.test']],
            scheme  => 'http',
        );
        $scope{'pagi.routing'} = $routing if defined $routing;
        my $context = PAGI::Context->new(\%scope, sub { }, sub { });

        like(
            dies { $context->path_for('page') },
            qr/\Apath_for requires a PAGI::Routing resolver in scope/,
            "$label is rejected by path_for",
        );
        like(
            dies { $context->url_for('page') },
            qr/\Aurl_for requires a PAGI::Routing resolver in scope/,
            "$label is rejected by url_for",
        );
    }
};

subtest 'Context paths add root_path only at the application boundary' => sub {
    my $routing = router(routes => [
        route('/items/{id}' => sub { }, name => 'item'),
        route('/' => sub { }, name => 'root'),
        route('//double/' => sub { }, name => 'double'),
    ]);
    my $resolver = PAGI::Routing::Resolver->new(routes => $routing->routes);

    is(
        _context('http', $resolver)->path_for('item', { id => 'one' }),
        '/items/one',
        'an empty root_path leaves the application path unchanged',
    );
    is(
        _context('http', $resolver, root_path => '/proxy/')
            ->path_for('item', { id => 'one' }, { q => 'two words' }),
        '/proxy/items/one?q=two%20words',
        'one boundary slash is removed while the generated query is retained',
    );
    is(
        _context('http', $resolver, root_path => '/')
            ->path_for('item', { id => 'one' }),
        '/items/one',
        'a root-only deployment prefix does not duplicate the leading slash',
    );
    is(
        _context('http', $resolver, root_path => '/proxy/')
            ->path_for('root'),
        '/proxy/',
        'an application root keeps one terminal boundary slash',
    );
    is(
        _context('http', $resolver, root_path => '/proxy/')
            ->path_for('double'),
        '/proxy//double/',
        'joining the boundary does not normalize route-internal slashes',
    );
    is(
        $routing->path_for('item', { id => 'one' }, { q => 'two words' }),
        '/items/one?q=two%20words',
        'router path_for remains request-independent',
    );
};

subtest 'url_for uses validated Host and only absent Host permits server fallback' => sub {
    my $resolver = _resolver(route('/page' => sub { }, name => 'page'));

    is(
        _context('http', $resolver,
            scheme  => 'https',
            headers => [['host', 'public.example:8443']],
            server  => ['internal.example', 9000],
        )->url_for('page'),
        'https://public.example:8443/page',
        'a validated Host with an explicit port wins over server',
    );
    is(
        _context('http', $resolver,
            scheme  => 'https',
            headers => [],
            server  => ['fallback.example', 9443],
        )->url_for('page'),
        'https://fallback.example:9443/page',
        'server supplies authority only when Host is absent',
    );

    like(
        dies {
            _context('http', $resolver,
                headers => [['host', 'bad host']],
                server  => ['fallback.example', 80],
            )->url_for('page');
        },
        qr/\Ainvalid authority/,
        'a malformed Host failure propagates without server fallback',
    );
    like(
        dies {
            _context('http', $resolver,
                headers => [['host', 'one.example'], ['Host', 'two.example']],
                server  => ['fallback.example', 80],
            )->url_for('page');
        },
        qr/\AHost header must occur at most once/,
        'a duplicate Host failure propagates without server fallback',
    );
    like(
        dies {
            _context('http', $resolver, headers => [], server => undef)
                ->url_for('page');
        },
        qr/\Ascope server cannot provide an authority/,
        'url_for croaks when neither Host nor server can supply authority',
    );
};

subtest 'url_for maps the request scheme according to the named route kind' => sub {
    my $resolver = _resolver(
        route('/page' => sub { }, name => 'page'),
        websocket('/socket' => sub { }, name => 'socket'),
        sse('/events' => sub { }, name => 'events'),
    );

    my @cases = (
        ['http target keeps http',             'page',   'http',
            'http://example.test/page'],
        ['http target keeps https',            'page',   'https',
            'https://example.test/page'],
        ['http target maps ws to http',        'page',   'ws',
            'http://example.test/page'],
        ['http target maps wss to https',      'page',   'wss',
            'https://example.test/page'],
        ['SSE target maps ws to http',         'events', 'ws',
            'http://example.test/events'],
        ['SSE target maps wss to https',       'events', 'wss',
            'https://example.test/events'],
        ['WebSocket target maps http to ws',   'socket', 'http',
            'ws://example.test/socket'],
        ['WebSocket target maps https to wss', 'socket', 'https',
            'wss://example.test/socket'],
        ['WebSocket target keeps ws',          'socket', 'ws',
            'ws://example.test/socket'],
        ['WebSocket target keeps wss',         'socket', 'wss',
            'wss://example.test/socket'],
    );

    for my $case (@cases) {
        my ($label, $name, $scope_scheme, $expected) = @$case;
        is(
            _context('http', $resolver, scheme => $scope_scheme)->url_for($name),
            $expected,
            $label,
        );
    }

    my $missing_scheme = _context('http', $resolver);
    delete $missing_scheme->scope->{scheme};
    is(
        $missing_scheme->url_for('page'),
        'http://example.test/page',
        'a missing scheme defaults to http',
    );
    like(
        dies { _context('http', $resolver, scheme => 'ftp')->url_for('page') },
        qr/\Aunsupported URL scheme/,
        'an unsupported scheme croaks instead of inventing a mapping',
    );
};

done_testing;
