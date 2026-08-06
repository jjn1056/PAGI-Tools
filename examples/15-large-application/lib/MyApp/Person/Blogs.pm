package MyApp::Person::Blogs;

use strict;
use warnings;
use PAGI::Routing qw(router route);
use MyApp::URL ();
use MyApp::View ();

sub list_blogs {
    my ($c) = @_;
    my $person_id = $c->path_param('person_id');
    my $data = $c->state->{data};
    my $person = $data->person($person_id);

    unless ($person) {
        return $c->html(
            MyApp::View->document(
                'Blogs not found',
                '    <h1>Blogs not found</h1>'
                    . "\n    <p>The requested person does not exist.</p>",
            ),
            status => 404,
        );
    }

    my $blogs = $data->blogs_for($person_id);
    my @items;
    for my $blog (@$blogs) {
        my $path = $c->path_for('show', { blog_id => $blog->{id} });
        push @items,
            qq{      <li><a href="$path">$blog->{title}</a></li>};
    }
    my $items = @items
        ? join("\n", @items)
        : '      <li>No posts yet.</li>';
    my $person_path = MyApp::URL->person($person_id);

    return $c->html(MyApp::View->document(
        "Blogs by $person->{name}",
        <<"BODY",
    <nav><a href="/">Home</a> / <a href="$person_path">$person->{name}</a></nav>
    <h1>Blogs by $person->{name}</h1>
    <ul>
$items
    </ul>
BODY
    ));
}

sub show_blog {
    my ($c) = @_;
    my $person_id = $c->path_param('person_id');
    my $blog_id = $c->path_param('blog_id');
    my $data = $c->state->{data};
    my $blog = $data->blog($person_id, $blog_id);

    unless ($blog) {
        my $blogs_path = MyApp::URL->blogs($person_id);
        return $c->html(
            MyApp::View->document(
                'Blog not found',
                qq{    <nav><a href="$blogs_path">Blogs</a></nav>}
                    . "\n    <h1>Blog not found</h1>"
                    . "\n    <p>No blog has that identifier.</p>",
            ),
            status => 404,
        );
    }

    my $blogs_path = MyApp::URL->blogs($person_id);
    my $person_path = MyApp::URL->person($person_id);
    return $c->html(MyApp::View->document(
        $blog->{title},
        <<"BODY",
    <nav><a href="/">Home</a> / <a href="$person_path">Person</a> / <a href="$blogs_path">Blogs</a></nav>
    <article>
      <h1>$blog->{title}</h1>
      <p>$blog->{body}</p>
    </article>
BODY
    ));
}

sub blogs_not_found {
    my ($c) = @_;
    my $person_id = $c->path_param('person_id');
    my $blogs_path = MyApp::URL->blogs($person_id);
    return $c->html(
        MyApp::View->document(
            'Blogs section not found',
            qq{    <nav><a href="$blogs_path">Blogs</a></nav>}
                . "\n    <h1>Blogs section not found</h1>"
                . "\n    <p>No Blogs route matched this path.</p>",
        ),
        status => 404,
    );
}

sub to_app {
    return router(
        routes => [
            route('/' => \&list_blogs, name => 'index'),
            route('/{blog_id}' => \&show_blog,
                name        => 'show',
                constraints => { blog_id => qr/\d+/ },
            ),
            route('/*path' => \&blogs_not_found),
        ],
    )->to_app;
}

1;
