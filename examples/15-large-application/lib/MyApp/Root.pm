package MyApp::Root;

use v5.40;
use PAGI::App::File;
use PAGI::Compose qw(compose);
use PAGI::Pages qw(welcome_page not_found_page);
use PAGI::Response qw(html_response);
use PAGI::Routing qw(router route mount request_app);
use PAGI::Routing::URL qw(path_for);
use MyApp::Data;
use MyApp::Person ();
use MyApp::View ();

sub startup($state, $scope) {
    $state->{data} = MyApp::Data->new;
    return;
}

sub shutdown($state, $scope) {
    delete $state->{data};
    return;
}

sub home($request) {
    my $state = $request->state
        or die 'MyApp::Root requires Compose lifespan state';
    my $people_path = path_for($request, '/person/index');
    my $pagi_path = path_for($request, '/pagi');
    my $count = scalar @{$state->get('data')->people};

    return html_response(MyApp::View->document(
        'My PAGI People',
        qq{    <h1>My PAGI People</h1>\n}
            . qq{    <p>This application contains $count people.</p>\n}
            . qq{    <p><a href="$people_path">Browse people</a></p>\n}
            . qq{    <p><a href="$pagi_path">PAGI welcome</a></p>},
    ));
}

sub pagi($request) {
    return welcome_page($request);
}

sub root_not_found($request) {
    return not_found_page($request,
        detail => 'No root route matched this path.');
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
                app => PAGI::App::File->from_app_path('static')),
            mount('/person',
                app  => MyApp::Person->routing,
                name => 'person',
                desc => 'People section',
            ),
        ],
        desc => 'MyApp root routes',
        http_default => request_app(\&root_not_found),
    );
}

sub to_app($class) {
    return compose(
        app      => $class->routing,
        lifespan => {
            startup  => \&startup,
            shutdown => \&shutdown,
        },
    );
}

1;
