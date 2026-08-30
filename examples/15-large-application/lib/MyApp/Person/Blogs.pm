package MyApp::Person::Blogs;

use v5.40;
use Types::Standard qw(Int);
use PAGI::Pages qw(not_found);
use PAGI::Response qw(html_response);
use PAGI::Routing qw(router route);
use PAGI::Routing::URL qw(path_for url_for);
use PAGI::Utils qw(request_response);
use MyApp::View ();

sub data($request) {
    my $state = $request->state
        or die 'MyApp::Person::Blogs requires Compose lifespan state';
    return $state->get('data');
}

sub list_blogs($request) {
    my $person_id = $request->path_param('person_id');
    my $data = data($request);
    my $person = $data->person($person_id);

    unless ($person) {
        return html_response(
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
        my $path = path_for($request, 'show', {
            blog_id => $blog->{id},
        });
        push @items,
            qq{      <li><a href="$path">$blog->{title}</a></li>};
    }

    # ../show resolves from /person/blog to /person/show and inherits person_id.
    my $person_path = path_for($request, '../show');

    return html_response(MyApp::View->document(
        "Blogs by $person->{name}",
        qq{    <a href="$person_path">$person->{name}</a>\n}
            . "    <h1>Blogs</h1>\n    <ul>\n"
            . join("\n", @items)
            . "\n    </ul>",
    ));
}

sub show_blog($request) {
    my $person_id = $request->path_param('person_id');
    my $blog_id = $request->path_param('blog_id');
    my $blog = data($request)->blog($person_id, $blog_id);

    unless ($blog) {
        my $blogs_path = path_for($request, 'index');
        return html_response(
            MyApp::View->document(
                'Blog not found',
                qq{    <a href="$blogs_path">Blogs</a>\n}
                    . '    <h1>Blog not found</h1>',
            ),
            status => 404,
        );
    }

    my $home_path = path_for($request, '/home');
    my $person_path = path_for($request, '../show');
    my $blogs_path = path_for($request, 'index');
    my $canonical = url_for($request, 'show',
        query    => { view => 'full' },
        fragment => 'comments',
    );

    return html_response(MyApp::View->document(
        $blog->{title},
        qq{    <a href="$home_path">Home</a> / }
            . qq{<a href="$person_path">Person</a> / }
            . qq{<a href="$blogs_path">Blogs</a>\n}
            . qq{    <article><h1>$blog->{title}</h1>}
            . qq{<p>$blog->{body}</p></article>\n}
            . qq{    <a href="$canonical">Comments view</a>},
    ));
}

sub blogs_not_found($request) {
    return not_found(
        detail => 'No Blogs route matched this path.');
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
        ],
        desc => 'Blog routes',
        http_default => request_response(\&blogs_not_found),
    );
}

1;
