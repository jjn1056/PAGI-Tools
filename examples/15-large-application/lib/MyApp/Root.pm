package MyApp::Root;

use v5.40;
use PAGI::App::File;
use PAGI::Compose qw(compose);
use PAGI::Pages;
use PAGI::Routing qw(router route mount);
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

sub home($c) {
    my $people_path = $c->path_for('/person/index');
    my $pagi_path = $c->path_for('/pagi');
    my $count = scalar @{$c->state->{data}->people};

    return $c->html(MyApp::View->document(
        'My PAGI People',
        qq{    <h1>My PAGI People</h1>\n}
            . qq{    <p>This application contains $count people.</p>\n}
            . qq{    <p><a href="$people_path">Browse people</a></p>\n}
            . qq{    <p><a href="$pagi_path">PAGI welcome</a></p>},
    ));
}

sub pagi($c) {
    return PAGI::Pages->welcome($c);
}

sub not_found($c) {
    return $c->html(
        MyApp::View->document(
            'Root page not found',
            "    <h1>Root page not found</h1>\n"
                . '    <p>No root route matched this path.</p>',
        ),
        status => 404,
    );
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
                desc => 'Pages Welcome response from Context',
            ),
            mount('/static' => PAGI::App::File->app_path('static')),
            mount('/person',
                router    => MyApp::Person->routing,
                name      => 'person',
                desc      => 'People section',
            ),
            route('/*path' => \&not_found,
                desc => 'Final root catchall',
            ),
        ],
        desc => 'MyApp root routes',
    );
}

sub to_app($class) {
    return compose(
        app      => $class->routing,
        lifespan => {
            startup  => \&startup,
            shutdown => \&shutdown,
        },
    )->to_app;
}

1;
