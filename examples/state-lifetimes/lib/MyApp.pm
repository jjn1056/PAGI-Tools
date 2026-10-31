package MyApp;
use v5.40;
use parent 'PAGI::App::Compose';
use Future::AsyncAwait;
use PAGI::State qw(singleton per_request factory);
use PAGI::Tools qw(middleware response route);
use MyApp::DB;
use MyApp::JoinForm;
use MyApp::Members;

# Serve it with
#   pagi-server -I examples/state-lifetimes/lib \
#       --app examples/state-lifetimes/lib/MyApp.pm
# or try one request without a server:
#   perl -I examples/state-lifetimes/lib examples/state-lifetimes/lib/MyApp.pm GET /

sub on_startup ($self, $state, $scope) {
    # A plain value, as always.
    $state->{access_log} = [];

    # One per worker, built on first use, in the order they are needed.
    # Both are Futures: connecting is I/O.
    $state->{db}      = singleton { MyApp::DB->connect };
    $state->{members} = singleton async sub ($state) {
        MyApp::Members->new(db => await $state->get('db'));
    };

    # One per request: the access log asks first, the handler gets the same answer.
    # The builder's second argument is a PAGI::HTTPConnection (a Request is one too).
    $state->{viewer} = per_request async sub ($state, $conn) {
        my $members = await $state->get('members');
        await $members->find_by_token($conn->cookie('token'));
    };

    # A new form for every submission, its store wired in.
    $state->{join_form} = factory async sub ($state, $conn) {
        MyApp::JoinForm->new(members => await $state->get('members'));
    };
}

async sub on_shutdown ($self, $state, $scope) {
    # Close the connection only if a request opened it.
    (await $state->{db}->value)->disconnect if $state->{db}->built;
}

sub app_middleware ($self) { [ middleware('+MyApp::Middleware::AccessLog') ] }

sub routes ($self) {
    return [
        route('/'     => \&home,       name => 'home'),
        route('/join' => \&add_member, methods => ['POST'], name => 'join'),
    ];
}

async sub home ($request) {
    my $state   = $request->state;
    my $viewer  = await $state->get('viewer');
    my $members = await $state->get('members');
    my $names   = join ', ', map { $_->{name} } $members->all->@*;
    my $hello   = $viewer ? "Hello $viewer->{name}. " : '';
    return response('Text', "${hello}Members: $names");
}

async sub add_member ($request) {
    my $form = await $request->state->get('join_form');
    await $form->process(await $request->form_params)
        or return response('JSON', { errors => $form->errors }, status => 422);
    return response('Redirect', '/', status => 303);
}

__PACKAGE__->run_if_script;
