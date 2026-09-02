package MyApp::API::User;
use parent 'PAGI::Endpoint::HTTP';
use strict;
use warnings;
use Future::AsyncAwait;

use PAGI::Pages qw(not_found);
use PAGI::Response qw(html_response);
use PAGI::State qw(app_state);

async sub get {
    my ($self, $request) = @_;
    my $state = app_state($request)
        or die 'endpoint-class-demo requires Compose lifespan state';
    $state->get('metrics')->{requests}++;

    my $user_id = $request->path_param('user_id');
    my ($user) = grep { $_->{id} == $user_id } @{$self->{users}};
    return html_response("<h1>$user->{name}</h1>") if $user;
    return not_found(detail => 'User not found');
}

1;
