#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::App::Router::Builder ();

{
    package Local::BuilderAlpha;
    sub Int { return qr/alpha/ }
    sub declare {
        my ($builder) = @_;
        $builder->get('/get/{id:&Int}' => sub { });
        $builder->post('/post/{id:&Int}' => sub { });
        $builder->put('/put/{id:&Int}' => sub { });
        $builder->patch('/patch/{id:&Int}' => sub { });
        $builder->delete('/delete/{id:&Int}' => sub { });
        $builder->head('/head/{id:&Int}' => sub { });
        $builder->options('/options/{id:&Int}' => sub { });
        $builder->any('/any/{id:&Int}' => sub { });
        $builder->route('/route/{id:&Int}' => sub { }, methods => ['RPC']);
        $builder->websocket('/socket/{id:&Int}' => sub { });
        $builder->sse('/events/{id:&Int}' => sub { });
    }
}

{
    package Local::BuilderBeta;
    sub Int { return qr/beta/ }
    sub declare {
        my ($builder) = @_;
        $builder->get('/get/{id:&Int}' => sub { });
        $builder->route('/route/{id:&Int}' => sub { }, methods => ['RPC']);
        $builder->websocket('/socket/{id:&Int}' => sub { });
        $builder->sse('/events/{id:&Int}' => sub { });
    }
}

{
    package Local::BuilderWrapper;
    sub Int { return qr/wrapper/ }
    sub declare { return $_[0]->get('/wrapped/{id:&Int}' => sub { }) }
}

{
    package Local::BuilderWrapperConsumer;
    sub Int { return qr/consumer/ }
    sub declare { return Local::BuilderWrapper::declare($_[0]) }
}

{
    package Local::BuilderRole;
    sub Int { return qr/role/ }
    sub declare { return $_[1]->get('/role/{id:&Int}' => sub { }) }
}

{
    package Local::BuilderRoleConsumer;
    sub Int { return qr/consumer/ }
    BEGIN { *declare = \&Local::BuilderRole::declare }
}

sub paths_match_provider {
    my ($nodes, $value) = @_;
    return [map {
        my $path = $_->path;
        $_->_pattern->match_route($path =~ s/\{id:&Int\}/$value/r);
    } @$nodes];
}

subtest 'each public-style builder declaration captures its direct package' => sub {
    my $alpha = PAGI::App::Router::Builder->new;
    my $beta = PAGI::App::Router::Builder->new;
    Local::BuilderAlpha::declare($alpha);
    Local::BuilderBeta::declare($beta);

    my $alpha_nodes = $alpha->_materialize_nodes(undef);
    my $beta_nodes = $beta->_materialize_nodes(undef);
    is(paths_match_provider($alpha_nodes, 'alpha'), [map { { id => 'alpha' } } @$alpha_nodes],
        'every Builder declaration method resolves &Int in the alpha caller package');
    is(paths_match_provider($beta_nodes, 'beta'), [map { { id => 'beta' } } @$beta_nodes],
        'get, route, websocket, and sse resolve &Int in the beta caller package');
    is(paths_match_provider($alpha_nodes, 'beta'), [map { undef } @$alpha_nodes],
        'alpha declarations do not rebind to another caller package');
    is(paths_match_provider($beta_nodes, 'alpha'), [map { undef } @$beta_nodes],
        'beta declarations do not rebind to another caller package');
};

subtest 'wrappers and role methods remain declaration-package boundaries' => sub {
    my $wrapper = PAGI::App::Router::Builder->new;
    Local::BuilderWrapperConsumer::declare($wrapper);
    my $wrapped = $wrapper->_materialize_nodes(undef)->[0];
    is($wrapped->_pattern->match_route('/wrapped/wrapper'), { id => 'wrapper' },
        'an actual wrapper resolves its own provider');
    is($wrapped->_pattern->match_route('/wrapped/consumer'), undef,
        'a wrapper does not search outward to its consumer provider');

    my $role = PAGI::App::Router::Builder->new;
    Local::BuilderRoleConsumer->declare($role);
    my $role_node = $role->_materialize_nodes(undef)->[0];
    is($role_node->_pattern->match_route('/role/role'), { id => 'role' },
        'a role-defined method resolves its role package provider');
    is($role_node->_pattern->match_route('/role/consumer'), undef,
        'a role method does not rebind to its consuming class provider');
};

done_testing;
