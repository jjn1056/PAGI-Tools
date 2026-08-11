use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use Scalar::Util qw(refaddr);
use lib "$Bin/../examples/15-large-application/lib";
use PAGI::Test::Client;

local $ENV{PAGI_HOME};
delete $ENV{PAGI_HOME};

if ($] < 5.040) {
    plan skip_all => 'examples/15-large-application requires Perl 5.40';
    exit 0;
}

require MyApp::Data;
require MyApp::Person;
require MyApp::Person::Blogs;
require MyApp::Root;
require MyApp::View;

sub _link_target {
    my ($response, $label) = @_;
    my ($href) = $response->text =~ m{<a href="([^"]*)">\Q$label\E</a>};
    die "no exact '$label' link in response HTML\n" unless defined $href;

    # Decode only the named entities this controlled href syntax permits.
    $href =~ s/&amp;/&/g;
    $href =~ s/&quot;/"/g;

    my $target = $href;
    $target =~ s{\Ahttp://testserver(?=/|\z)}{};
    $target =~ s/#.*\z//;

    return ($href, $target);
}

sub _follow_link {
    my ($client, $response, $label) = @_;
    my ($href, $target) = _link_target($response, $label);
    return {
        href     => $href,
        target   => $target,
        response => $client->get($target),
    };
}

sub _source_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!\n";
    local $/;
    my $source = <$fh>;
    close $fh or die "cannot close $path: $!\n";
    return $source;
}

subtest 'example sources require Perl 5.40 and use signatures' => sub {
    my $root = "$Bin/../examples/15-large-application";
    my @sources = (
        "$root/app.pl",
        "$root/lib/MyApp/Data.pm",
        "$root/lib/MyApp/Root.pm",
        "$root/lib/MyApp/Person.pm",
        "$root/lib/MyApp/Person/Blogs.pm",
        "$root/lib/MyApp/View.pm",
    );

    for my $path (@sources) {
        my $source = _source_text($path);
        like($source, qr/^use v5[.]40;/m, "$path declares the example minimum");
        unlike($source, qr/^use warnings;/m,
            "$path relies on the Perl 5.40 warning bundle");
        unlike($source, qr/my\s*\([^;]*\)\s*=\s*\@_\s*;/,
            "$path contains no legacy argument unpacking");
    }

    my $data = _source_text("$root/lib/MyApp/Data.pm");
    my $root_app = _source_text("$root/lib/MyApp/Root.pm");
    my $person = _source_text("$root/lib/MyApp/Person.pm");
    my $blogs = _source_text("$root/lib/MyApp/Person/Blogs.pm");
    my $view = _source_text("$root/lib/MyApp/View.pm");

    unlike($root_app, qr/use PAGI::Utils qw\(app_path\)/,
        'Root no longer needs the functional application path helper');
    like($root_app,
        qr/mount\('\/static'\s*=>\s*PAGI::App::File->app_path\('static'\)\)/,
        'static mount uses the concise App File component constructor');
    unlike($root_app, qr/PAGI::App::File->new\s*\(|File::Basename|File::Spec|__FILE__|\$STATIC_ROOT/,
        'Root contains no manual or expanded static-root construction');

    like($data, qr/sub new\(\$class\)/, 'Data constructor uses a signature');
    like($root_app, qr/sub routing\(\$class\)/, 'Root routing uses a signature');
    like($person, qr/sub show_person\(\$c\)/, 'Person handler uses a signature');
    like($blogs, qr/sub show_blog\(\$c\)/, 'Blogs handler uses a signature');
    like($view, qr/sub document\(\$class, \$title, \$body\)/,
        'View document helper uses a signature');

    like($person, qr/use Types::Standard qw\(Int\)/,
        'Person imports the Type::Tiny Int provider');
    is(() = $person =~ /\{person_id:&Int\}/g, 2,
        'Person uses &Int on its detail and Blogs mount parameters');
    like($blogs, qr/use Types::Standard qw\(Int\)/,
        'Blogs imports the Type::Tiny Int provider');
    is(() = $blogs =~ /\{blog_id:&Int\}/g, 1,
        'Blogs uses &Int on its detail parameter');
};

subtest 'fixture repository exposes defensive people and blog records' => sub {
    my $data = MyApp::Data->new;

    is(
        $data->people,
        [
            {
                id      => '1',
                name    => 'Ada Lovelace',
                summary => 'Mathematician and writer',
            },
            {
                id      => '2',
                name    => 'Grace Hopper',
                summary => 'Computer scientist and naval officer',
            },
            {
                id      => '3',
                name    => 'Margaret Hamilton',
                summary => 'Software engineer',
            },
        ],
        'people are returned in fixture order',
    );

    my $person = $data->person('1');
    $person->{name} = 'Changed';
    is($data->person('1')->{name}, 'Ada Lovelace',
        'person returns a defensive copy');
    is($data->person('999'), undef, 'missing person returns undef');

    my $blogs = $data->blogs_for('1');
    is([map { $_->{id} } @$blogs], ['101', '102'],
        'person blogs retain fixture order');
    $blogs->[0]{title} = 'Changed';
    is(
        $data->blog('1', '101')->{title},
        'Notes on the Analytical Engine',
        'blog records are defensive copies',
    );
    is($data->blogs_for('3'), [], 'known person may have no blogs');
    is($data->blogs_for('999'), undef,
        'missing person has no blog collection');
    is($data->blog('1', '999'), undef, 'missing blog returns undef');
};

subtest 'component routing publishes the canonical composed address map' => sub {
    my @classes = qw(MyApp::Root MyApp::Person MyApp::Person::Blogs);
    my $all_routing = 1;
    for my $class (@classes) {
        my $has_routing = $class->can('routing');
        ok($has_routing, "$class exposes routing");
        $all_routing = 0 unless $has_routing;
    }

    unless ($all_routing) {
        fail('the composed address map is unavailable without all routing methods');
        return;
    }

    my $root = MyApp::Root->routing;
    my $person = MyApp::Person->routing;
    my $blogs = MyApp::Person::Blogs->routing;
    isa_ok($root, 'PAGI::Routing::Router');
    isa_ok($person, 'PAGI::Routing::Router');
    isa_ok($blogs, 'PAGI::Routing::Router');

    is(
        {
            '/home' => $root->path_for('/home'),
            '/person/index' => $root->path_for('/person/index'),
            '/person/show' => $root->path_for(
                '/person/show', { person_id => 2 },
            ),
            '/person/show-negative' => $root->path_for(
                '/person/show', { person_id => -1 },
            ),
            '/person/blog/index' => $root->path_for(
                '/person/blog/index', { person_id => 2 },
            ),
            '/person/blog/show' => $root->path_for(
                '/person/blog/show', { person_id => 2, blog_id => 201 },
            ),
        },
        {
            '/home' => '/',
            '/person/index' => '/person/',
            '/person/show' => '/person/2',
            '/person/show-negative' => '/person/-1',
            '/person/blog/index' => '/person/2/blog/',
            '/person/blog/show' => '/person/2/blog/201',
        },
        'Root exposes the five canonical logical addresses and URL patterns',
    );
    is(
        [sort keys %{$root->named_routes}],
        [qw(
            /home
            /person/blog/index
            /person/blog/show
            /person/index
            /person/show
        )],
        'Root publishes exactly the five named leaves',
    );

    my ($home_source) = grep {
        defined $_->name && $_->name eq 'home'
    } @{$root->routes};
    my ($person_mount) = grep {
        defined $_->name && $_->name eq 'person'
    } @{$root->routes};
    my $mounted_person = $person_mount->router;
    my ($blog_mount) = grep {
        defined $_->name && $_->name eq 'blog'
    } @{$mounted_person->routes};
    my $mounted_blogs = $blog_mount->router;

    is(refaddr($root->route_named('/home')), refaddr($home_source),
        'home address preserves its Root source leaf');
    is(
        refaddr($root->route_named('/person/index')),
        refaddr($mounted_person->route_named('/index')),
        'Person index preserves its source leaf through composition',
    );
    is(
        refaddr($root->route_named('/person/show')),
        refaddr($mounted_person->route_named('/show')),
        'Person detail preserves its source leaf through composition',
    );
    is(
        refaddr($root->route_named('/person/blog/index')),
        refaddr($mounted_blogs->route_named('/index')),
        'Blogs index preserves its source leaf through composition',
    );
    is(
        refaddr($root->route_named('/person/blog/show')),
        refaddr($mounted_blogs->route_named('/show')),
        'Blog detail preserves its source leaf through composition',
    );
};

subtest 'legacy URL helper is absent' => sub {
    my $url_module = join '/',
        "$Bin/../examples/15-large-application/lib", 'MyApp', 'URL' . '.pm';
    ok(!-e $url_module, 'the legacy URL helper file is no longer present');
};

subtest 'component handlers keep application hrefs behind Context reverse calls' => sub {
    my $component_root = "$Bin/../examples/15-large-application/lib/MyApp";
    my @components = (
        ['Root', "$component_root/Root.pm", 0],
        ['Person', "$component_root/Person.pm", 0],
        ['Blogs', "$component_root/Person/Blogs.pm", 1],
    );

    for my $component (@components) {
        my ($label, $path, $uses_url_for) = @$component;
        my $source = _source_text($path);
        unlike(
            $source,
            qr{href\s*=\s*["'](?:/|https?://)},
            "$label handlers contain no literal application href",
        );
        like(
            $source,
            qr{\$c->path_for\s*\(},
            "$label handlers generate paths through Context",
        );
        like(
            $source,
            qr{\$c->url_for\s*\(},
            "$label handlers generate absolute URLs through Context",
        ) if $uses_url_for;
    }
};

subtest 'application View owns the shared HTML document shell' => sub {
    my $html = MyApp::View->document('Fixture title', '    <h1>Body</h1>');
    like($html, qr{<!doctype html>}, 'document declares HTML');
    like($html, qr{<title>Fixture title</title>}, 'document uses its title');
    like($html, qr{href="/static/app.css"}, 'document links shared CSS');
    like($html, qr{    <h1>Body</h1>}, 'document includes owned body markup');
};

subtest 'Root composes lifespan, Router links, and owned outcomes' => sub {
    my $routing = MyApp::Root->routing;
    my $direct_app = MyApp::Root->to_app;
    is(ref($direct_app), 'CODE', 'Root class compiles to a PAGI app');

    my $app_file = "$Bin/../examples/15-large-application/app.pl";
    my $app = do $app_file;
    my $load_error = $@ || $!;
    ok(!$load_error, 'minimal app.pl loads cleanly') or diag($load_error);
    is(ref($app), 'CODE', 'app.pl returns Root compiled as a PAGI app');

    my $state;
    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;
        $state = $client->state;
        isa_ok($state->{data}, 'MyApp::Data');

        my ($ada) = grep {
            $_->{name} eq 'Ada Lovelace'
        } @{$state->{data}->people};
        my ($first_blog) = @{$state->{data}->blogs_for($ada->{id})};
        my $home_target = '/';

        my $people_path = $routing->path_for('/person/index');
        my $person_path = $routing->path_for(
            '/person/show', { person_id => $ada->{id} },
        );
        my $blogs_path = $routing->path_for(
            '/person/blog/index', { person_id => $ada->{id} },
        );
        my $blog_path = $routing->path_for(
            '/person/blog/show', {
                person_id => $ada->{id},
                blog_id   => $first_blog->{id},
            },
        );

        my $home = $client->get($home_target);
        is($home->status, 200, 'Root home responds');
        like($home->text, qr{<h1>My PAGI People</h1>},
            'Root home renders startup-backed fixture data');

        my $people_link = _follow_link($client, $home, 'Browse people');
        is($people_link->{href}, $people_path,
            'Root renders the canonical Person index path');
        my $people = $people_link->{response};
        is($people->status, 200, 'Root-to-Person generated link is followed');
        like($people->text, qr{<h1>People</h1>},
            'followed Person index renders its page');
        my $person_link = _follow_link($client, $people, $ada->{name});
        is($person_link->{href}, $person_path,
            'Person renders Ada detail with its relative route name');
        my $person = $person_link->{response};
        is($person->status, 200, 'Person index-to-detail link is followed');
        like($person->text, qr{<h1>Ada Lovelace</h1>},
            'followed Person detail renders fixture content');

        my $blogs_link = _follow_link($client, $person, 'Read blogs');
        is($blogs_link->{href}, $blogs_path,
            'Person renders the inherited Blogs index path');
        my $blogs = $blogs_link->{response};
        is($blogs->status, 200, 'Person-to-Blogs generated link is followed');
        like($blogs->text, qr{<h1>Blogs</h1>},
            'followed Blogs index renders its page');

        my $blog_link = _follow_link(
            $client, $blogs, $first_blog->{title},
        );
        is($blog_link->{href}, $blog_path,
            'Blogs renders detail with inherited person_id and explicit blog_id');
        my $blog = $blog_link->{response};
        is($blog->status, 200, 'Blogs index-to-detail link is followed');
        like($blog->text, qr{<h1>Notes on the Analytical Engine</h1>},
            'followed Blog detail renders fixture content');

        my $home_link = _follow_link($client, $blog, 'Home');
        is($home_link->{target}, $home_target,
            'Blog detail renders its graph-wide Root link');
        is($home_link->{response}->status, 200,
            'Blog-to-Root generated link is followed');

        my $back_person = _follow_link($client, $blog, 'Person');
        is($back_person->{target}, $person_link->{target},
            'Blog detail renders its relative Person link');
        is($back_person->{response}->status, 200,
            'Blog-to-Person generated link is followed');

        my $back_blogs = _follow_link($client, $blog, 'Blogs');
        is($back_blogs->{target}, $blogs_link->{target},
            'Blog detail renders its relative Blogs link');
        is($back_blogs->{response}->status, 200,
            'Blog-to-Blogs generated link is followed');

        my $comments = _follow_link($client, $blog, 'Comments view');
        my $comments_href = 'http://testserver' . $routing->path_for(
            '/person/blog/show',
            params => {
                person_id => $ada->{id},
                blog_id   => $first_blog->{id},
            },
            query    => { view => 'full' },
            fragment => 'comments',
        );
        my $comments_target = $routing->path_for(
            '/person/blog/show',
            params => {
                person_id => $ada->{id},
                blog_id   => $first_blog->{id},
            },
            query => { view => 'full' },
        );
        is(
            $comments->{href},
            $comments_href,
            'url_for preserves absolute authority, query, and fragment in HTML',
        );
        is(
            $comments->{target},
            $comments_target,
            'the follower removes only test authority and fragment',
        );
        is($comments->{response}->status, 200,
            'query/fragment generated link is followed');
        like(
            $comments->{response}->text,
            qr{<h1>Notes on the Analytical Engine</h1>},
            'comments request reaches the same Blog handler',
        );

        my $person_missing = $client->get('/person/999');
        is($person_missing->status, 404,
            'matched missing person is a local handler 404');
        like($person_missing->text, qr{<h1>Person not found</h1>},
            'Person handler 404 remains untouched');

        my $negative_person = $client->get('/person/-1');
        is($negative_person->status, 404,
            'signed Int routes a negative person identifier to the handler');
        like($negative_person->text, qr{<h1>Person not found</h1>},
            'negative person identifiers receive the branded handler-owned 404');

        my $noninteger_person = $client->get('/person/not-an-integer');
        is($noninteger_person->status, 404,
            'a noninteger person identifier does not reach the typed leaf');
        is($noninteger_person->text, 'Not Found',
            'a noninteger person identifier keeps the child Router generated 404');
        unlike($noninteger_person->text, qr{<h1>Person not found</h1>},
            'the generated noninteger response is not the branded handler 404');

        my $blog_missing = $client->get('/person/1/blog/999');
        is($blog_missing->status, 404,
            'matched missing blog is a local handler 404');
        like($blog_missing->text, qr{<h1>Blog not found</h1>},
            'Blogs handler 404 remains untouched');

        my $blogs_catchall = $client->get('/person/1/blog/not/a/route');
        is($blogs_catchall->status, 404,
            'Blogs explicit catchall owns deeper paths');
        like($blogs_catchall->text, qr{<h1>Blogs section not found</h1>},
            'Blogs catchall body remains local');

        my $root_missing = $client->get('/outside');
        is($root_missing->status, 404, 'Root catchall handles root miss');
        like($root_missing->text, qr{<h1>Root page not found</h1>},
            'Root catchall is an ordinary branded route');

        my $child_none = $client->get('/person/1/unmatched');
        is($child_none->status, 404,
            'current Person Router mount owns its routing NONE');
        is($child_none->text, 'Not Found',
            'GAP-02 evidence: generated child 404 cannot bubble to Root');

        my $wrong_method = $client->post('/person/1/blog/101');
        is($wrong_method->status, 405, 'child PARTIAL remains final');
        is($wrong_method->header('Allow'), 'GET, HEAD',
            'child 405 carries the normalized Allow header');

        my $css = $client->get('/static/app.css');
        is($css->status, 200, 'static stylesheet is mounted');
        is($css->header('Content-Type'), 'text/css',
            'opaque file app selects the CSS media type');
        like($css->text, qr/\.page\s*\{/,
            'mounted stylesheet contains its recognizable page rule');

        my $static_missing = $client->get('/static/missing.css');
        is($static_missing->status, 404,
            'missing static asset remains owned by the opaque file app');
        unlike($static_missing->text, qr{<h1>Root page not found</h1>},
            'opaque application 404 is not reinterpreted as Root decline');

        my $head = $client->head($person_link->{target});
        is($head->status, 200, 'automatic HEAD reaches Person GET');
        is($head->content, '', 'HEAD suppresses the HTML body');
        is(
            $head->header('Content-Length'),
            $person->header('Content-Length'),
            'HEAD preserves GET-equivalent Content-Length',
        );
    });

    ok(!exists $state->{data},
        'Root shutdown removes Data from the same server state');
};

done_testing;
