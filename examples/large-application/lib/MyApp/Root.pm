package MyApp::Root;

# The application. Serve it with
#   pagi-server -I examples/large-application/lib \
#       --app examples/large-application/lib/MyApp/Root.pm
# or try one request without a server:
#   perl -I examples/large-application/lib examples/large-application/lib/MyApp/Root.pm GET /

use v5.40;
use parent 'PAGI::App::Compose';
use PAGI::App::File;
use PAGI::Pages qw(welcome not_found);
use PAGI::Response qw(response);
use PAGI::Routing qw(router route mount);
use PAGI::Routing::URL qw(path_for);
use MyApp::Data;
use MyApp::Person ();
use MyApp::View ();

sub on_startup($self, $state, $scope) {
    $state->{data} = MyApp::Data->new;
    return;
}

sub on_shutdown($self, $state, $scope) {
    delete $state->{data};
    return;
}

sub home($request) {
    my $state = $request->state
        or die 'MyApp::Root requires Compose lifespan state';
    my $people_path = path_for($request, '/person/index');
    my $pagi_path = path_for($request, '/pagi');
    my $count = scalar @{$state->get('data')->people};

    return response('HTML', MyApp::View->document(
        $request,
        'My PAGI People',
        qq{    <h1>My PAGI People</h1>\n}
            . qq{    <p>This application contains $count people.</p>\n}
            . qq{    <p><a href="$people_path">Browse people</a></p>\n}
            . qq{    <p><a href="$pagi_path">PAGI welcome</a></p>},
    ));
}

sub pagi($request) {
    return welcome();
}

sub routing($class) {
    return router(
        routes => [
            route('/' => \&home,
                name => 'home',
                desc => 'HTML landing page',
            ),
            route('/pagi' => \&pagi,
                name => 'pagi',
                desc => 'Pages Welcome response from Request',
            ),
            mount('/static',
                app  => PAGI::App::File->from_app_path('static'),
                name => 'static',
            ),
            mount('/person',
                app  => MyApp::Person->routing,
                name => 'person',
                desc => 'People section',
            ),
        ],
        desc => 'MyApp root routes',
        http_default => not_found(
            detail => 'No root route matched this path.'),
    );
}

# The one Compose boundary: the root Router behind an unnamed root mount,
# with on_startup and on_shutdown as its lifespan.
sub routes($self) {
    return [
        mount('/' => app => $self->routing),
    ];
}

__PACKAGE__->run_if_script;
