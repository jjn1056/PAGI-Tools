package MyApp::Root;

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use PAGI::App::File;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(router route mount);
use MyApp::Data;
use MyApp::Person ();
use MyApp::View ();

my $STATIC_ROOT = File::Spec->catdir(
    dirname(__FILE__), '..', '..', 'static',
);

sub startup {
    my ($state, $scope) = @_;
    $state->{data} = MyApp::Data->new;
    return;
}

sub shutdown {
    my ($state, $scope) = @_;
    delete $state->{data};
    return;
}

sub home {
    my ($c) = @_;
    my $people_path = $c->path_for('/person/index');
    my $count = scalar @{$c->state->{data}->people};

    return $c->html(MyApp::View->document(
        'My PAGI People',
        qq{    <h1>My PAGI People</h1>\n}
            . qq{    <p>This application contains $count people.</p>\n}
            . qq{    <p><a href="$people_path">Browse people</a></p>},
    ));
}

sub not_found {
    my ($c) = @_;
    return $c->html(
        MyApp::View->document(
            'Root page not found',
            "    <h1>Root page not found</h1>\n"
                . '    <p>No root route matched this path.</p>',
        ),
        status => 404,
    );
}

sub routing {
    my ($class) = @_;

    return router(
        routes => [
            route('/' => \&home,
                name => 'home',
                desc => 'HTML landing page',
            ),
            mount('/static' => PAGI::App::File->new(
                root => $STATIC_ROOT,
            )),
            mount('/person',
                router    => MyApp::Person->routing,
                namespace => 'person',
                desc      => 'People section',
            ),
            route('/*path' => \&not_found,
                desc => 'Final root catchall',
            ),
        ],
        desc => 'MyApp root routes',
    );
}

sub to_app {
    my ($class) = @_;

    return compose(
        app      => $class->routing,
        lifespan => {
            startup  => \&startup,
            shutdown => \&shutdown,
        },
    )->to_app;
}

1;
