package MyApp::Person;

use strict;
use warnings;
use utf8;
use PAGI::Routing qw(router route mount);
use MyApp::URL ();
use MyApp::View ();

sub list_people {
    my ($c) = @_;
    my $people = $c->state->{data}->people;
    my @items;

    for my $person (@$people) {
        my $path = $c->path_for('show', { person_id => $person->{id} });
        push @items,
            qq{      <li><a href="$path">$person->{name}</a> — $person->{summary}</li>};
    }

    my $items = join("\n", @items);
    return $c->html(MyApp::View->document(
        'People',
        <<"BODY",
    <nav><a href="/">Home</a></nav>
    <h1>People</h1>
    <ul>
$items
    </ul>
BODY
    ));
}

sub show_person {
    my ($c) = @_;
    my $person_id = $c->path_param('person_id');
    my $person = $c->state->{data}->person($person_id);

    unless ($person) {
        my $people_path = MyApp::URL->people;
        return $c->html(
            MyApp::View->document(
                'Person not found',
                qq{    <nav><a href="$people_path">People</a></nav>}
                    . "\n    <h1>Person not found</h1>"
                    . "\n    <p>No person has that identifier.</p>",
            ),
            status => 404,
        );
    }

    my $people_path = MyApp::URL->people;
    my $blogs_path = MyApp::URL->blogs($person_id);
    return $c->html(MyApp::View->document(
        $person->{name},
        <<"BODY",
    <nav><a href="/">Home</a> / <a href="$people_path">People</a></nav>
    <h1>$person->{name}</h1>
    <p>$person->{summary}</p>
    <p><a href="$blogs_path">Read this person's blogs</a></p>
BODY
    ));
}

sub to_app {
    return router(
        routes => [
            route('/' => \&list_people, name => 'index'),
            route('/{person_id}' => \&show_person,
                name        => 'show',
                constraints => { person_id => qr/\d+/ },
            ),
            mount('/{person_id}/blog' => 'MyApp::Person::Blogs',
                constraints => { person_id => qr/\d+/ },
            ),
        ],
    )->to_app;
}

1;
