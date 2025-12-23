package MyApp::API;
use parent 'PAGI::Endpoint::Router';
use strict;
use warnings;
use Future::AsyncAwait;

my @USERS = (
    { id => 1, name => 'Alice', email => 'alice@example.com' },
    { id => 2, name => 'Bob', email => 'bob@example.com' },
);

async sub on_startup {
    my ($self) = @_;
    warn "API subrouter starting...\n";
    $self->stash->{api_version} = 'v1';
}

sub routes {
    my ($self, $r) = @_;

    $r->get('/info' => 'get_info');
    $r->get('/users' => 'list_users');
    $r->get('/users/:id' => 'get_user');
    $r->post('/users' => 'create_user');
}

async sub get_info {
    my ($self, $req, $res) = @_;

    await $res->json({
        app     => $req->stash->{config}{app_name},
        version => $req->stash->{config}{version},
        api     => $req->stash->{api_version},
    });
}

async sub list_users {
    my ($self, $req, $res) = @_;
    await $res->json(\@USERS);
}

async sub get_user {
    my ($self, $req, $res) = @_;

    my $id = $req->param('id');
    my ($user) = grep { $_->{id} == $id } @USERS;

    if ($user) {
        await $res->json($user);
    } else {
        await $res->status(404)->json({ error => 'User not found' });
    }
}

async sub create_user {
    my ($self, $req, $res) = @_;

    my $data = await $req->json;

    my $new_user = {
        id    => scalar(@USERS) + 1,
        name  => $data->{name},
        email => $data->{email},
    };
    push @USERS, $new_user;

    await $res->status(201)->json($new_user);
}

1;
