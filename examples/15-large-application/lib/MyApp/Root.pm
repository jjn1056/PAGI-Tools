package MyApp::Root;

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use PAGI::App::File;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(route mount);
use MyApp::Data;
use MyApp::URL ();
use MyApp::View ();

my $STATIC_ROOT = File::Spec->catdir(
    dirname(__FILE__),
    '..',
    '..',
    'static',
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
    my $count = scalar @{$c->state->{data}->people};
    my $people_path = MyApp::URL->people;
    return $c->html(MyApp::View->document(
        'My PAGI People',
        <<"BODY",
    <h1>My PAGI People</h1>
    <p>This modular application contains $count fixture people.</p>
    <p><a href="$people_path">Browse people</a></p>
BODY
    ));
}

sub not_found {
    my ($c) = @_;
    return $c->html(
        MyApp::View->document(
            'Root page not found',
            '    <h1>Root page not found</h1>'
                . "\n    <p>No application route matched this path.</p>",
        ),
        status => 404,
    );
}

sub _static_app {
    return PAGI::App::File->new(root => $STATIC_ROOT);
}

sub to_app {
    return compose(
        routes => [
            route('/' => \&home, name => 'home'),
            mount('/static' => _static_app()),
            mount('/person' => 'MyApp::Person'),
            route('/*path' => \&not_found),
        ],
        lifespan => {
            startup  => \&startup,
            shutdown => \&shutdown,
        },
    )->to_app;
}

1;
