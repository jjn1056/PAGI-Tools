#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Routing::Pattern;
use PAGI::Routing qw(route mount);

{
    package Local::RoutingType;

    sub new {
        my ($class, $expected) = @_;
        return bless { expected => $expected, seen => [] }, $class;
    }

    sub check {
        my ($self, $value) = @_;
        push @{$self->{seen}}, $value;
        return $value eq $self->{expected};
    }

    sub get_message {
        my ($self, $value) = @_;
        return "expected $self->{expected}, got $value";
    }

    sub seen { [ @{$_[0]->{seen}} ] }
}

subtest 'literal and parameter routes are exact over decoded paths' => sub {
    my $literal = PAGI::Routing::Pattern->new(
        path => '/users', mode => 'route', constraints => {},
    );
    isa_ok($literal, 'PAGI::Routing::Pattern');
    is($literal->path, '/users', 'declared route path is preserved');
    is($literal->parameters, [], 'literal route has no parameters');
    is($literal->match_route('/users'), {}, 'literal route matches exactly');
    ok(!defined $literal->match_route('/users/'), 'trailing slash remains exact');

    my $slash = PAGI::Routing::Pattern->new(
        path => '/users/', mode => 'route', constraints => {},
    );
    is($slash->match_route('/users/'), {}, 'declared trailing slash matches');
    ok(!defined $slash->match_route('/users'), 'declared trailing slash is required');

    my $braced = PAGI::Routing::Pattern->new(
        path => '/users/{id}', mode => 'route', constraints => {},
    );
    is($braced->parameters, ['id'], 'braced parameter is described');
    is($braced->match_route('/users/42'), { id => '42' }, 'braced parameter captures one segment');
    my $scope = { path => "/users/caf\x{e9} value" };
    is(
        $braced->match_route($scope->{path}),
        { id => "caf\x{e9} value" },
        'already percent-decoded scope path is captured unchanged',
    );
    ok(!defined $braced->match_route('/users/a/b'), 'normal parameter cannot cross a separator');

    my $legacy = PAGI::Routing::Pattern->new(
        path => '/legacy/:id', mode => 'route', constraints => {},
    );
    is($legacy->parameters, ['id'], 'legacy parameter is described');
    is($legacy->match_route('/legacy/abc'), { id => 'abc' }, 'legacy parameter captures one segment');

    my $embedded = PAGI::Routing::Pattern->new(
        path => '/artifacts/item-{id}.json', mode => 'route', constraints => {},
    );
    is(
        $embedded->match_route('/artifacts/item-42.json'),
        { id => '42' },
        'ordinary parameter token may be surrounded by quoted literal text',
    );

    like(
        dies {
            PAGI::Routing::Pattern->new(
                path => '/duplicate/{id}/:id', mode => 'route', constraints => {},
            );
        },
        qr/duplicate path parameter 'id'/,
        'duplicate parameter names are rejected',
    );
    like(
        dies {
            PAGI::Routing::Pattern->new(
                path => 'missing/slash', mode => 'route', constraints => {},
            );
        },
        qr/path must begin with '\/'/,
        'declared paths require a leading slash',
    );

    my $metacharacters = PAGI::Routing::Pattern->new(
        path => '/literal.+()[]?^$', mode => 'route', constraints => {},
    );
    is(
        $metacharacters->match_route('/literal.+()[]?^$'),
        {},
        'regex metacharacters in literal text are quoted',
    );
    ok(!defined $metacharacters->match_route('/literalX'), 'literal metacharacters cannot act as regex');
};

subtest 'wildcards are one terminal whole segment and preserve decoded input' => sub {
    my $files = PAGI::Routing::Pattern->new(
        path => '/files/*path', mode => 'route', constraints => {},
    );
    is($files->parameters, ['path'], 'wildcard name is described');
    is($files->match_route('/files/'), { path => '' }, 'wildcard may be empty');
    is($files->match_route('/files/a/b'), { path => 'a/b' }, 'wildcard keeps slash');
    is(
        $files->match_route('/files/../private//key'),
        { path => '../private//key' },
        'decoded wildcard traversal-like text and empty components are unchanged',
    );
    ok(!defined $files->match_route('/files'), 'wildcard separator remains exact');

    my $root = PAGI::Routing::Pattern->new(
        path => '/*rest', mode => 'route', constraints => {},
    );
    is($root->match_route('/'), { rest => '' }, 'root wildcard may be empty');
    is($root->match_route('/a//b'), { rest => 'a//b' }, 'root wildcard preserves internal separators');

    like(
        dies {
            PAGI::Routing::Pattern->new(
                path => '/files/prefix*path', mode => 'route', constraints => {},
            );
        },
        qr/wildcard must occupy a whole segment/,
        'embedded wildcard is rejected',
    );
    like(
        dies {
            PAGI::Routing::Pattern->new(
                path => '/files/*path/more', mode => 'route', constraints => {},
            );
        },
        qr/wildcard must be terminal/,
        'nonterminal wildcard is rejected',
    );
    like(
        dies {
            PAGI::Routing::Pattern->new(
                path => '/files/*one/*two', mode => 'route', constraints => {},
            );
        },
        qr/(?:only one wildcard|wildcard must be terminal)/,
        'repeated wildcard is rejected',
    );
};

subtest 'mounts match decoded segment prefixes with normalized slash semantics' => sub {
    my $api = PAGI::Routing::Pattern->new(
        path => '/api', mode => 'mount', constraints => {},
    );
    is($api->path, '/api', 'mount declaration without trailing slash is stable');
    is(
        $api->match_mount('/api'),
        { captures => {}, consumed => '/api', remainder => '/' },
        'exact mount prefix leaves slash remainder',
    );
    is(
        $api->match_mount('/api/'),
        { captures => {}, consumed => '/api', remainder => '/' },
        'trailing request slash is the exact-prefix remainder',
    );
    is(
        $api->match_mount('/api/users'),
        { captures => {}, consumed => '/api', remainder => '/users' },
        'mount consumes a segment-aligned prefix',
    );
    ok(!defined $api->match_mount('/apix'), 'mount cannot match inside a segment');

    my $api_slash = PAGI::Routing::Pattern->new(
        path => '/api/', mode => 'mount', constraints => {},
    );
    is($api_slash->path, '/api', 'non-root mount trailing slash is normalized');
    is(
        $api_slash->match_mount('/api/v1'),
        { captures => {}, consumed => '/api', remainder => '/v1' },
        'normalized trailing-slash declaration has identical prefix semantics',
    );

    my $tenant = PAGI::Routing::Pattern->new(
        path => '/tenants/{tenant}', mode => 'mount', constraints => {},
    );
    is(
        $tenant->match_mount('/tenants/acme/users'),
        {
            captures => { tenant => 'acme' },
            consumed => '/tenants/acme',
            remainder => '/users',
        },
        'parameterized mount reports captures, consumed prefix, and remainder',
    );
    is(
        $tenant->match_mount('/tenants/acme'),
        {
            captures => { tenant => 'acme' },
            consumed => '/tenants/acme',
            remainder => '/',
        },
        'exact parameterized prefix leaves slash remainder',
    );

    my $root = PAGI::Routing::Pattern->new(
        path => '/', mode => 'mount', constraints => {},
    );
    is($root->path, '/', 'root mount declaration remains slash');
    is(
        $root->match_mount('/anything'),
        { captures => {}, consumed => '', remainder => '/anything' },
        'root mount consumes nothing',
    );
    is(
        $root->match_mount('/'),
        { captures => {}, consumed => '', remainder => '/' },
        'root mount preserves root remainder',
    );

    like(
        dies {
            PAGI::Routing::Pattern->new(
                path => '/assets/*path', mode => 'mount', constraints => {},
            );
        },
        qr/mount paths do not allow wildcards/,
        'mount wildcard is rejected',
    );
};

subtest 'constraints are anchored synchronous validators and never coercions' => sub {
    my $explicit = PAGI::Routing::Pattern->new(
        path => '/digits/{id}', mode => 'route', constraints => { id => qr/\d+/ },
    );
    is($explicit->match_route('/digits/123'), { id => '123' }, 'explicit regex accepts a full match');
    ok(!defined $explicit->match_route('/digits/x123'), 'explicit regex rejects a leading partial match');
    ok(!defined $explicit->match_route("/digits/123\n"), 'explicit regex rejects a decoded trailing newline');

    my $inline = PAGI::Routing::Pattern->new(
        path => '/inline/{id:\d+}', mode => 'route', constraints => {},
    );
    is($inline->match_route('/inline/456'), { id => '456' }, 'inline regex uses the shared matcher');
    ok(!defined $inline->match_route('/inline/456x'), 'inline regex rejects a trailing partial match');
    ok(!defined $inline->match_route("/inline/456\n"), 'inline regex rejects a decoded trailing newline');

    my $slash_inline = PAGI::Routing::Pattern->new(
        path => '/inline-slash/{value:[^/]+}', mode => 'route', constraints => {},
    );
    is(
        $slash_inline->match_route('/inline-slash/value'),
        { value => 'value' },
        'inline regex text may contain a path-separator character class',
    );

    my $quantified;
    is(
        dies {
            $quantified = PAGI::Routing::Pattern->new(
                path => '/fixed/{id:\d{2}}', mode => 'route', constraints => {},
            );
        },
        undef,
        'regex quantifier braces do not terminate the route token',
    );
    is(
        $quantified ? $quantified->match_route('/fixed/42') : undef,
        { id => '42' },
        'quantified inline regex matches after safe tokenization',
    );

    my $escaped_brace;
    is(
        dies {
            $escaped_brace = PAGI::Routing::Pattern->new(
                path => '/escaped-brace/{value:\}}', mode => 'route', constraints => {},
            );
        },
        undef,
        'escaped closing brace does not terminate the route token',
    );
    is(
        $escaped_brace ? $escaped_brace->match_route('/escaped-brace/}') : undef,
        { value => '}' },
        'escaped closing brace remains part of the inline regex',
    );

    my $class_brace;
    is(
        dies {
            $class_brace = PAGI::Routing::Pattern->new(
                path => '/class-brace/{value:[}]}', mode => 'route', constraints => {},
            );
        },
        undef,
        'closing brace inside a character class does not terminate the route token',
    );
    is(
        $class_brace ? $class_brace->match_route('/class-brace/}') : undef,
        { value => '}' },
        'character-class closing brace remains part of the inline regex',
    );

    my $comment_brace;
    is(
        dies {
            $comment_brace = PAGI::Routing::Pattern->new(
                path => '/comment-brace/{value:(?#})x}', mode => 'route', constraints => {},
            );
        },
        undef,
        'a closing brace inside a regex comment does not terminate the route token',
    );
    is(
        $comment_brace ? $comment_brace->match_route('/comment-brace/x') : undef,
        { value => 'x' },
        'the inline regex remains intact after a comment containing a closing brace',
    );

    my @unterminated = (
        ['missing outer token delimiter', '/bad/{id:\d+'],
        ['unclosed nested regex brace', '/bad/{id:\d{2}'],
        ['unclosed character class', '/bad/{id:[abc}'],
        ['dangling escape at EOF', '/bad/{id:\d+' . '\\'],
    );
    for my $case (@unterminated) {
        my ($description, $path) = @$case;
        like(
            dies {
                PAGI::Routing::Pattern->new(
                    path => $path, mode => 'route', constraints => {},
                );
            },
            qr/\Aunterminated inline constraint for 'id'/,
            "$description is rejected during construction",
        );
    }

    my $literal_newline = PAGI::Routing::Pattern->new(
        path => "/literal\n", mode => 'route', constraints => {},
    );
    is($literal_newline->match_route("/literal\n"), {}, 'literal trailing newline is matched only when declared');
    ok(!defined $literal_newline->match_route('/literal'), 'literal trailing newline is not discarded');

    my @predicate_calls;
    my $predicate = sub {
        push @predicate_calls, [ @_ ];
        return $_[0] eq 'accepted' ? 'not a replacement' : '';
    };
    my $predicated = PAGI::Routing::Pattern->new(
        path => '/predicate/{value}', mode => 'route', constraints => { value => $predicate },
    );
    is(
        $predicated->match_route('/predicate/accepted'),
        { value => 'accepted' },
        'truthy predicate validates without replacing the capture',
    );
    ok(!defined $predicated->match_route('/predicate/rejected'), 'false predicate produces no match');
    is(
        \@predicate_calls,
        [ ['accepted'], ['rejected'] ],
        'predicate receives exactly the decoded captured string and no Context',
    );

    my $throwing = PAGI::Routing::Pattern->new(
        path => '/throw/{value}', mode => 'route',
        constraints => { value => sub { die "constraint exploded\n" } },
    );
    like(
        dies { $throwing->match_route('/throw/value') },
        qr/^constraint exploded/,
        'predicate exception propagates',
    );

    my $async = PAGI::Routing::Pattern->new(
        path => '/async/{value}', mode => 'route',
        constraints => { value => sub { Future->done(1) } },
    );
    like(
        dies { $async->match_route('/async/value') },
        qr/route constraints must be synchronous; got Future/,
        'Future-returning predicate is rejected',
    );

    my $type = Local::RoutingType->new('typed');
    my $typed = PAGI::Routing::Pattern->new(
        path => '/typed/{value}', mode => 'route', constraints => { value => $type },
    );
    is($typed->match_route('/typed/typed'), { value => 'typed' }, 'check object accepts a value');
    ok(!defined $typed->match_route('/typed/other'), 'check object rejects a value');
    is($type->seen, ['typed', 'other'], 'check object receives each captured string');

    my @both_calls;
    my $both = PAGI::Routing::Pattern->new(
        path => '/both/{id:\d+}', mode => 'route',
        constraints => { id => sub { push @both_calls, $_[0]; return $_[0] < 100 } },
    );
    ok(!defined $both->match_route('/both/not-digits'), 'inline constraint may reject first');
    is(\@both_calls, [], 'explicit checker is not called after inline rejection');
    is($both->match_route('/both/42'), { id => '42' }, 'inline and explicit constraints may both pass');
    ok(!defined $both->match_route('/both/123'), 'explicit constraint may reject after inline acceptance');
    is(\@both_calls, ['42', '123'], 'inline then explicit checker order is stable');

    my @declaration_order;
    my $ordered = PAGI::Routing::Pattern->new(
        path => '/pair/{first}/{second}', mode => 'route',
        constraints => {
            second => sub { push @declaration_order, 'second'; return 1 },
            first  => sub { push @declaration_order, 'first'; return 1 },
        },
    );
    is($ordered->match_route('/pair/a/b'), { first => 'a', second => 'b' }, 'multiple constrained captures match');
    is(\@declaration_order, ['first', 'second'], 'explicit checkers follow path declaration order');

    my $declared = { value => $predicate };
    my $described = PAGI::Routing::Pattern->new(
        path => '/copy/{value}', mode => 'route', constraints => $declared,
    );
    $declared->{value} = qr/replaced/;
    my $returned = $described->constraints;
    is(refaddr($returned->{value}), refaddr($predicate), 'declared checker identity is retained');
    $returned->{value} = qr/mutated/;
    is(
        refaddr($described->constraints->{value}),
        refaddr($predicate),
        'public constraint hash is a defensive copy',
    );

    like(
        dies {
            PAGI::Routing::Pattern->new(
                path => '/known/{id}', mode => 'route', constraints => { missing => qr/.+/ },
            );
        },
        qr/constraint 'missing' does not name a path parameter/,
        'constraint names must be declared in the path',
    );
    like(
        dies {
            PAGI::Routing::Pattern->new(
                path => '/known/{id}', mode => 'route', constraints => { id => 'digits' },
            );
        },
        qr/constraint 'id' must be a Regexp, coderef, or check object/,
        'invalid constraint types are rejected immediately',
    );
};

subtest 'rendering encodes components and validates exact unencoded parameters' => sub {
    my $literal = PAGI::Routing::Pattern->new(
        path => "/caf\x{e9} space/%", mode => 'route', constraints => {},
    );
    is($literal->render({}, 'literal'), '/caf%C3%A9%20space/%25', 'decoded literal text is UTF-8 percent encoded');

    my $user = PAGI::Routing::Pattern->new(
        path => '/users/{id}', mode => 'route', constraints => {},
    );
    is(
        $user->render({ id => "A z/caf\x{e9}?#%" }, 'user.show'),
        '/users/A%20z%2Fcaf%C3%A9%3F%23%25',
        'normal parameter renders as one encoded component with uppercase escapes',
    );
    is($user->render({ id => '-._~AZaz09' }, 'user.show'), '/users/-._~AZaz09', 'only unreserved bytes stay literal');
    like(
        dies { $user->render({}, 'user.show') },
        qr/missing path parameter 'id'.*user\.show/,
        'missing path parameter is rejected with route identity',
    );
    like(
        dies { $user->render({ id => 42, extra => 1 }, 'user.show') },
        qr/unexpected path parameter 'extra'.*user\.show/,
        'extra path parameter is rejected with route identity',
    );

    my $files = PAGI::Routing::Pattern->new(
        path => '/files/*path', mode => 'route', constraints => {},
    );
    is($files->render({ path => '' }, 'files'), '/files/', 'empty wildcard renders after its separator');
    is(
        $files->render({ path => "../private//caf\x{e9}/" }, 'files'),
        '/files/../private//caf%C3%A9/',
        'wildcard encodes components independently and preserves empty components',
    );

    my @render_values;
    my $constrained = PAGI::Routing::Pattern->new(
        path => '/search/{term}', mode => 'route',
        constraints => {
            term => sub {
                push @render_values, [ @_ ];
                return $_[0] eq "caf\x{e9} value";
            },
        },
    );
    is(
        $constrained->render({ term => "caf\x{e9} value" }, 'search'),
        '/search/caf%C3%A9%20value',
        'constraint sees unencoded value before successful rendering',
    );
    like(
        dies { $constrained->render({ term => 'wrong' }, 'search') },
        qr/path parameter 'term' failed constraint.*search/,
        'constraint rejection croaks during rendering',
    );
    is(
        \@render_values,
        [ ["caf\x{e9} value"], ['wrong'] ],
        'render predicate remains unary and receives unencoded input',
    );

    my @combined_render_values;
    my $combined = PAGI::Routing::Pattern->new(
        path => "/combined/{value:caf\x{e9} value}", mode => 'route',
        constraints => {
            value => sub {
                push @combined_render_values, [ @_ ];
                return 1;
            },
        },
    );
    like(
        dies { $combined->render({ value => 'wrong' }, 'combined') },
        qr/path parameter 'value' failed constraint.*combined/,
        'inline render checker rejects before the explicit checker',
    );
    is(
        \@combined_render_values,
        [],
        'explicit render checker is not called after inline rejection',
    );
    is(
        $combined->render({ value => "caf\x{e9} value" }, 'combined'),
        '/combined/caf%C3%A9%20value',
        'inline and explicit render checkers both accept before encoding',
    );
    is(
        \@combined_render_values,
        [ ["caf\x{e9} value"] ],
        'explicit render checker receives the same unencoded value after inline acceptance',
    );

    my $type = Local::RoutingType->new('right');
    my $typed = PAGI::Routing::Pattern->new(
        path => '/typed/{value}', mode => 'route', constraints => { value => $type },
    );
    like(
        dies { $typed->render({ value => 'wrong' }, 'typed') },
        qr/expected right, got wrong/,
        'check-object render diagnostic uses get_message when available',
    );

    my $async = PAGI::Routing::Pattern->new(
        path => '/async/{value}', mode => 'route',
        constraints => { value => sub { Future->done(1) } },
    );
    like(
        dies { $async->render({ value => 'x' }, 'async') },
        qr/route constraints must be synchronous; got Future/,
        'reverse validation also rejects Future-returning constraints',
    );
};

subtest 'route and mount descriptions expose compiled pattern metadata defensively' => sub {
    my $id_constraint = qr/\d+/;
    my $route_constraints = { id => $id_constraint };
    my $leaf = route('/users/{id}' => sub { }, name => 'user.show', constraints => $route_constraints);
    is($leaf->path, '/users/{id}', 'route path comes from compiled pattern description');
    is($leaf->parameters, ['id'], 'route exposes a copied parameter list');
    $route_constraints->{id} = qr/replaced/;
    my $leaf_constraints = $leaf->constraints;
    is(refaddr($leaf_constraints->{id}), refaddr($id_constraint), 'route preserves declared checker identity');
    $leaf_constraints->{id} = qr/mutated/;
    is(refaddr($leaf->constraints->{id}), refaddr($id_constraint), 'route constraint accessor stays defensive');

    my $tenant_constraint = qr/[a-z]+/;
    my $mount_constraints = { tenant => $tenant_constraint };
    my $mounted = mount('/tenants/{tenant}/', routes => [], constraints => $mount_constraints);
    is($mounted->path, '/tenants/{tenant}', 'mount path comes from normalized compiled pattern description');
    is($mounted->parameters, ['tenant'], 'mount exposes a copied parameter list');
    $mount_constraints->{tenant} = qr/replaced/;
    my $returned_mount_constraints = $mounted->constraints;
    is(refaddr($returned_mount_constraints->{tenant}), refaddr($tenant_constraint), 'mount preserves checker identity');
    $returned_mount_constraints->{tenant} = qr/mutated/;
    is(refaddr($mounted->constraints->{tenant}), refaddr($tenant_constraint), 'mount constraint accessor stays defensive');

    like(
        dies { route('/plain' => sub { }, constraints => { id => qr/\d+/ }) },
        qr/constraint 'id' does not name a path parameter/,
        'route construction compiles and validates its private pattern',
    );
    like(
        dies { mount('/plain', routes => [], constraints => { id => 'digits' }) },
        qr/constraint 'id' does not name a path parameter|constraint 'id' must be/,
        'mount construction compiles and validates its private pattern',
    );
};

done_testing;
