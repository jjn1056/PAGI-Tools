package MyApp::Person;

use v5.40;
use utf8;
use Types::Standard qw(Int);
use PAGI::Routing qw(router route mount);
use MyApp::Person::Blogs ();
use MyApp::View ();

sub list_people($c) {
    my @items;

    for my $person (@{$c->state->{data}->people}) {
        my $path = $c->path_for('show', {
            person_id => $person->{id},
        });
        push @items,
            qq{      <li><a href="$path">$person->{name}</a></li>};
    }

    return $c->html(MyApp::View->document(
        'People',
        "    <h1>People</h1>\n    <ul>\n"
            . join("\n", @items)
            . "\n    </ul>",
    ));
}

sub show_person($c) {
    my $person_id = $c->path_param('person_id');
    my $person = $c->state->{data}->person($person_id);

    unless ($person) {
        my $people_path = $c->path_for('index');
        return $c->html(
            MyApp::View->document(
                'Person not found',
                qq{    <a href="$people_path">People</a>\n}
                    . '    <h1>Person not found</h1>',
            ),
            status => 404,
        );
    }

    # Relative resolution finds /person/blog/index and inherits person_id.
    my $blogs_path = $c->path_for('blog/index');
    my $home_path = $c->path_for('/home');

    return $c->html(MyApp::View->document(
        $person->{name},
        qq{    <a href="$home_path">Home</a>\n}
            . qq{    <h1>$person->{name}</h1>\n}
            . qq{    <p>$person->{summary}</p>\n}
            . qq{    <a href="$blogs_path">Read blogs</a>},
    ));
}

sub routing($class) {
    return router(
        routes => [
            route('/' => \&list_people,
                name => 'index',
                desc => 'List people',
            ),
            route('/{person_id:&Int}' => \&show_person,
                name => 'show',
                desc => 'Show one person',
            ),
            mount('/{person_id:&Int}/blog',
                app  => MyApp::Person::Blogs->routing,
                name => 'blog',
                desc => 'Blogs for one person',
            ),
        ],
        desc => 'Person routes',
    );
}

1;
