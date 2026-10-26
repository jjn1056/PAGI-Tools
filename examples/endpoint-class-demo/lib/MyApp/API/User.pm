package MyApp::API::User;
use parent 'PAGI::Endpoint::HTTP';
use strict;
use warnings;
use Future::AsyncAwait;

use PAGI::Pages qw(not_found);
use PAGI::Response qw(response);

async sub get {
    my ($self, $request) = @_;
    my $state = $request->state;
    $state->get('metrics')->{requests}++;

    my $user_id = $request->path_param('user_id');
    my ($user) = grep { $_->{id} == $user_id } @{$self->{users}};
    return response('HTML', "<h1>$user->{name}</h1>") if $user;
    return not_found(detail => 'User not found');
}

1;
