package MyApp::API;
use parent 'PAGI::Endpoint::Router';
use strict;
use warnings;
use Future::AsyncAwait;

my @USERS = (
    { id => 1, name => 'Alice', email => 'alice@example.com' },
    { id => 2, name => 'Bob', email => 'bob@example.com' },
);

# Note: Subrouters mounted via mount() don't receive lifespan events.
# Use lazy initialization or access parent state via $req->stash if needed.

sub _ensure_state {
    my ($self) = @_;
    return if $self->state->{_initialized};

    $self->state->{api_version} = 'v1';
    $self->state->{config} = {
        app_name => 'Endpoint Router Demo',
        version  => '1.0.0',
    };
    $self->state->{_initialized} = 1;
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

    # Lazy initialize state (subrouters don't get on_startup)
    $self->_ensure_state;

    my $config = $self->state->{config};

    await $res->json({
        app     => $config->{app_name},
        version => $config->{version},
        api     => $self->state->{api_version},
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
