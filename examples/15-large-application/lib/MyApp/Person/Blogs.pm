package MyApp::Person::Blogs;

use v5.40;
use warnings;
use Types::Standard qw(Int);
use PAGI::Routing qw(router route);
use MyApp::View ();

sub list_blogs($c) {
    my $person_id = $c->path_param('person_id');
    my $data = $c->state->{data};
    my $person = $data->person($person_id);

    unless ($person) {
        return $c->html(
            MyApp::View->document(
                'Blogs not found',
                '    <h1>Blogs not found</h1>',
            ),
            status => 404,
        );
    }

    my @items;
    for my $blog (@{$data->blogs_for($person_id)}) {
        # blog_id is explicit; person_id is inherited from the match.
        my $path = $c->path_for('show', {
            blog_id => $blog->{id},
        });
        push @items,
            qq{      <li><a href="$path">$blog->{title}</a></li>};
    }

    # ../show resolves from /person/blog to /person/show and inherits person_id.
    my $person_path = $c->path_for('../show');

    return $c->html(MyApp::View->document(
        "Blogs by $person->{name}",
        qq{    <a href="$person_path">$person->{name}</a>\n}
            . "    <h1>Blogs</h1>\n    <ul>\n"
            . join("\n", @items)
            . "\n    </ul>",
    ));
}

sub show_blog($c) {
    my $person_id = $c->path_param('person_id');
    my $blog_id = $c->path_param('blog_id');
    my $blog = $c->state->{data}->blog($person_id, $blog_id);

    unless ($blog) {
        my $blogs_path = $c->path_for('index');
        return $c->html(
            MyApp::View->document(
                'Blog not found',
                qq{    <a href="$blogs_path">Blogs</a>\n}
                    . '    <h1>Blog not found</h1>',
            ),
            status => 404,
        );
    }

    my $home_path = $c->path_for('/home');
    my $person_path = $c->path_for('../show');
    my $blogs_path = $c->path_for('index');
    my $canonical = $c->url_for('show',
        query    => { view => 'full' },
        fragment => 'comments',
    );

    return $c->html(MyApp::View->document(
        $blog->{title},
        qq{    <a href="$home_path">Home</a> / }
            . qq{<a href="$person_path">Person</a> / }
            . qq{<a href="$blogs_path">Blogs</a>\n}
            . qq{    <article><h1>$blog->{title}</h1>}
            . qq{<p>$blog->{body}</p></article>\n}
            . qq{    <a href="$canonical">Comments view</a>},
    ));
}

sub blogs_not_found($c) {
    # The unnamed catchall still has /person/blog as its containing namespace.
    my $blogs_path = $c->path_for('index');
    return $c->html(
        MyApp::View->document(
            'Blogs section not found',
            qq{    <a href="$blogs_path">Blogs</a>\n}
                . '    <h1>Blogs section not found</h1>',
        ),
        status => 404,
    );
}

sub routing($class) {
    return router(
        routes => [
            route('/' => \&list_blogs,
                name => 'index',
                desc => 'List one person\'s blogs',
            ),
            route('/{blog_id:&Int}' => \&show_blog,
                name => 'show',
                desc => 'Show one blog',
            ),
            route('/*path' => \&blogs_not_found,
                desc => 'Blogs-local catchall',
            ),
        ],
        desc => 'Blog routes',
    );
}

1;
