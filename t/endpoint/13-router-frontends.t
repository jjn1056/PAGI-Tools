#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Endpoint::Router ();
use PAGI::Test::Client ();

sub scope {
    my (%changes) = @_;
    return {
        type => 'http', method => 'GET', path => '/', raw_path => '/', root_path => '',
        path_params => {}, headers => [], %changes,
    };
}

sub run_scope {
    my ($app, $request_scope) = @_;
    my @events;
    $app->(
        $request_scope,
        sub { return Future->done({ type => 'unused.receive' }) },
        sub { push @events, $_[0]; return Future->done },
    )->get;
    return \@events;
}

{
    package Local::TreeEndpoint;
    use parent 'PAGI::Endpoint::Router';

    sub new {
        my ($class, %args) = @_;
        return bless { label => $args{label}, child => $args{child}, seen => [] }, $class;
    }

    sub routes {
        my ($self, $r) = @_;
        $r->get('/http/{leaf}' => 'http_leaf')->name('http');
        $r->websocket('/ws/{leaf}' => 'ws_leaf')->name('ws');
        $r->sse('/sse/{leaf}' => 'sse_leaf')->name('sse');
        if ($self->{child}) {
            $r->mount('/child/{child}', router => $self->{child})
                ->name('child')->desc($self->{label} . ' child');
        }
    }

    sub _record {
        my ($self, $kind, $c) = @_;
        my $record = {
            kind => $kind,
            receiver => Scalar::Util::refaddr($self),
            context => ref($c),
            params => { %{$c->scope->{path_params}} },
            relative => $c->path_for($kind),
            absolute => defined $self->{absolute_prefix}
                ? $c->path_for(
                    $self->{absolute_prefix} . "/$kind",
                    { %{$c->scope->{path_params}} },
                )
                : undef,
            scope_id => Scalar::Util::refaddr($c->scope),
        };
        push @{$self->{seen}}, $record;
        return $record;
    }

    sub http_leaf {
        my ($self, $c) = @_;
        my $record = $self->_record('http', $c);
        return $c->text(join ':', $self->{label}, @{$record->{params}}{sort keys %{$record->{params}}});
    }

    sub ws_leaf {
        my ($self, $c) = @_;
        $self->_record('ws', $c);
        return $c->close(1000, $self->{label});
    }

    sub sse_leaf {
        my ($self, $c) = @_;
        $self->_record('sse', $c);
        $c->start->get;
        return $c->close;
    }
}

{
    package Local::TreeRoot;
    use parent 'PAGI::Endpoint::Router';
    sub new {
        my ($class, %args) = @_;
        return bless { people => $args{people}, seen => [] }, $class;
    }
    sub routes {
        my ($self, $r) = @_;
        $r->get('/root/{leaf}' => 'http_leaf')->name('root-http');
        $r->websocket('/root-ws/{leaf}' => 'ws_leaf')->name('root-ws');
        $r->sse('/root-sse/{leaf}' => 'sse_leaf')->name('root-sse');
        $r->mount('/orgs/{org}', router => $self->{people})->name('people');
    }
    sub _record {
        my ($self, $kind, $c) = @_;
        push @{$self->{seen}}, [$kind, Scalar::Util::refaddr($self), ref($c),
            { %{$c->scope->{path_params}} }];
    }
    sub http_leaf { $_[0]->_record('http', $_[1]); return $_[1]->text('root') }
    sub ws_leaf { $_[0]->_record('ws', $_[1]); return $_[1]->close(1000, 'root') }
    sub sse_leaf {
        $_[0]->_record('sse', $_[1]); $_[1]->start->get; return $_[1]->close;
    }
}

sub make_tree {
    my $blogs = Local::TreeEndpoint->new(label => 'blogs');
    $blogs->{absolute_prefix} = '/people/child';
    my $people = Local::TreeEndpoint->new(label => 'people', child => $blogs);
    $people->{absolute_prefix} = '/people';
    my $root = Local::TreeRoot->new(people => $people);
    return ($root, $people, $blogs);
}

subtest 'nested Endpoint objects materialize in one root and keep all protocol receivers' => sub {
    my ($root, $people, $blogs) = make_tree();
    my $root_id = refaddr($root);
    my $people_id = refaddr($people);
    my $blogs_id = refaddr($blogs);
    my $routing = $root->to_router;
    my $app = $routing->to_app;
    my $client = PAGI::Test::Client->new(app => $app);

    is($routing->path_for('/people/http', { org => 'acme', leaf => 'p' }),
        '/orgs/acme/http/p', 'absolute path_for crosses the first Endpoint mount');
    is($routing->path_for('/people/child/http', {
            org => 'acme', child => 'alice', leaf => 'b',
        }), '/orgs/acme/child/alice/http/b',
        'absolute path_for composes parameters across both Endpoint mounts');
    is([sort keys %{$routing->named_routes}], [qw(
        /people/child/http /people/child/sse /people/child/ws
        /people/http /people/sse /people/ws /root-http /root-sse /root-ws
    )], 'local slash segments form canonical absolute names');

    is($client->get('/root/r')->text, 'root', 'root HTTP method runs');
    is($client->get('/orgs/acme/http/p')->status, 200, 'People HTTP method runs');
    is($client->get('/orgs/acme/child/alice/http/b')->status, 200,
        'Blogs HTTP method runs with composed captures');

    for my $case (
        [websocket => '/root-ws/r', 'root'],
        [websocket => '/orgs/acme/ws/p', 'people'],
        [websocket => '/orgs/acme/child/alice/ws/b', 'blogs'],
    ) {
        my ($type, $path, $reason) = @$case;
        is(run_scope($app, scope(type => $type, path => $path, raw_path => $path)),
            [{ type => 'websocket.close', code => 1000, reason => $reason }],
            "$reason WebSocket method runs");
    }
    for my $case (
        [sse => '/root-sse/r', 'root'],
        [sse => '/orgs/acme/sse/p', 'people'],
        [sse => '/orgs/acme/child/alice/sse/b', 'blogs'],
    ) {
        my ($type, $path, $label) = @$case;
        is(run_scope($app, scope(type => $type, path => $path, raw_path => $path)), [
            { type => 'sse.start', status => 200 },
            { type => 'sse.close' },
        ], "$label SSE method runs");
    }

    is([map { $_->[1] } @{$root->{seen}}], [($root_id) x 3],
        'root HTTP, WebSocket, and SSE methods retain root identity');
    is([map { $_->{receiver} } @{$people->{seen}}], [($people_id) x 3],
        'People protocol methods retain the nested object identity');
    is([map { $_->{receiver} } @{$blogs->{seen}}], [($blogs_id) x 3],
        'Blogs protocol methods retain the deepest object identity');
    is($blogs->{seen}[0]{params}, { org => 'acme', child => 'alice', leaf => 'b' },
        'the deepest handler sees captures from every placement');
    is([$blogs->{seen}[0]{relative}, $blogs->{seen}[0]{absolute}],
        ['/orgs/acme/child/alice/http/b', '/orgs/acme/child/alice/http/b'],
        'Context relative and absolute path_for agree inside nested Endpoint objects');
};

{
    package Local::ReuseRoot;
    use parent 'PAGI::Endpoint::Router';
    sub new { bless { child => $_[1] }, $_[0] }
    sub routes {
        my ($self, $r) = @_;
        $r->mount('/left/{org}', router => $self->{child})->name('left');
        $r->mount('/right/{org}', router => $self->{child})->name('right');
    }
}

subtest 'same-object siblings reuse one snapshot while placement metadata stays isolated' => sub {
    my $child = Local::TreeEndpoint->new(label => 'shared');
    my $root = Local::ReuseRoot->new($child);
    my $routing = $root->to_router;
    my $nodes = $routing->routes;
    is(refaddr($nodes->[0]->router), refaddr($nodes->[1]->router),
        'one nested Endpoint object becomes one child Router per root snapshot');
    isnt(refaddr($nodes->[0]), refaddr($nodes->[1]),
        'sibling placements remain distinct immutable Mount nodes');
    is([map { [$_->path, $_->name] } @$nodes],
        [['/left/{org}', 'left'], ['/right/{org}', 'right']],
        'placement path and local name remain isolated');

    my $app = $routing->to_app;
    PAGI::Test::Client->new(app => $app)->get('/left/acme/http/one');
    PAGI::Test::Client->new(app => $app)->get('/right/beta/http/two');
    is([map { $_->{relative} } @{$child->{seen}}],
        ['/left/acme/http/one', '/right/beta/http/two'],
        'relative reverse routing uses each active sibling placement');
    isnt($child->{seen}[0]{scope_id}, $child->{seen}[1]{scope_id},
        'the two placements receive isolated request scope clones');
    is([map { $_->{params} } @{$child->{seen}}], [
        { org => 'acme', leaf => 'one' },
        { org => 'beta', leaf => 'two' },
    ], 'captures do not leak between reused placements');

    my $fresh = $root->to_router->routes;
    isnt(refaddr($nodes->[0]->router), refaddr($fresh->[0]->router),
        'a later root snapshot rematerializes the Endpoint child');
    is(refaddr($fresh->[0]->router), refaddr($fresh->[1]->router),
        'the later snapshot independently reuses one child identity');
};

{
    package Local::CycleEndpoint;
    use parent 'PAGI::Endpoint::Router';
    sub new { bless {}, $_[0] }
    sub routes {
        my ($self, $r) = @_;
        $r->mount($self->{path}, router => $self->{other})->name($self->{name});
    }
}

subtest 'two Endpoint objects report a materialization cycle' => sub {
    my $a = Local::CycleEndpoint->new;
    my $b = Local::CycleEndpoint->new;
    @$a{qw(path name other)} = ('/b', 'b', $b);
    @$b{qw(path name other)} = ('/a', 'a', $a);
    like(dies { $a->to_router }, qr{/b:b.*->.*/a:a},
        'cycle diagnostic includes both Endpoint placement names in order');
};

{
    package Local::ProviderChildEndpoint;
    use parent 'PAGI::Endpoint::Router';
    sub routes { $_[1]->get('/leaf' => 'leaf')->name('leaf') }
    sub leaf {
        my ($self, $c) = @_;
        return $c->text('mount ' . $c->path_param('mount'));
    }
}

{
    package Local::ProviderEndpoint;
    use parent 'PAGI::Endpoint::Router';
    sub Int { return qr/\A\d+\z/ }
    sub new {
        my ($class, %args) = @_;
        return bless {
            mode => $args{mode}, child => Local::ProviderChildEndpoint->new,
        }, $class;
    }
    sub routes {
        my ($self, $r) = @_;
        if ($self->{mode} eq 'group') {
            $r->group('/group/{group:&Int}' => sub {
                $_[0]->get('/leaf' => 'group_leaf')->name('leaf');
            })->name('group');
        }
        else {
            $r->mount('/mount/{mount:&Int}', router => $self->{child})
                ->name('mount');
        }
    }
    sub group_leaf {
        my ($self, $c) = @_;
        return $c->text('group ' . $c->path_param('group'));
    }
}

subtest 'a group prefix resolves its provider in the Endpoint package' => sub {
    my $endpoint = Local::ProviderEndpoint->new(mode => 'group');
    my $routing = $endpoint->to_router;
    my $client = PAGI::Test::Client->new(app => $routing->to_app);

    is($client->get('/group/12/leaf')->text, 'group 12',
        'an unqualified group-prefix provider resolves in the Endpoint package');
    is($client->get('/group/no/leaf')->status, 404,
        'the Endpoint group provider rejects a nonmatching capture');
};

subtest 'a routing-aware mount prefix resolves its provider in the Endpoint package' => sub {
    my $endpoint = Local::ProviderEndpoint->new(mode => 'mount');
    my $routing = $endpoint->to_router;
    my $client = PAGI::Test::Client->new(app => $routing->to_app);

    is($client->get('/mount/34/leaf')->text, 'mount 34',
        'an unqualified mount-prefix provider resolves in the Endpoint package');
    is($client->get('/mount/no/leaf')->status, 404,
        'the Endpoint mount provider rejects a nonmatching capture');
};

done_testing;
