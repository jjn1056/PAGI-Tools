package MyApp::Person;

use v5.40;
use utf8;
use Types::Standard qw(Int);
use PAGI::Response qw(html_response);
use PAGI::Routing qw(router route mount);
use PAGI::Routing::URL qw(path_for);
use MyApp::Person::Blogs ();
use MyApp::View ();

sub data($request) {
    my $state = $request->state
        or die 'MyApp::Person requires Compose lifespan state';
    return $state->get('data');
}

sub list_people($request) {
    my @items;

    for my $person (@{data($request)->people}) {
        my $path = path_for($request, 'show', {
            person_id => $person->{id},
        });
        push @items,
            qq{      <li><a href="$path">$person->{name}</a></li>};
    }

    return html_response(MyApp::View->document(
        'People',
        "    <h1>People</h1>\n    <ul>\n"
            . join("\n", @items)
            . "\n    </ul>",
    ));
}

sub show_person($request) {
    my $person_id = $request->path_param('person_id');
    my $person = data($request)->person($person_id);

    unless ($person) {
        my $people_path = path_for($request, 'index');
        return html_response(
            MyApp::View->document(
                'Person not found',
                qq{    <a href="$people_path">People</a>\n}
                    . '    <h1>Person not found</h1>',
            ),
            status => 404,
        );
    }

    # Relative resolution finds /person/blog/index and inherits person_id.
    my $blogs_path = path_for($request, 'blog/index');
    my $home_path = path_for($request, '/home');

    return html_response(MyApp::View->document(
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
