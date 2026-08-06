use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../examples/15-large-application/lib";

use MyApp::Data;
use MyApp::URL;
use MyApp::Root ();
use MyApp::View;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(mount);
use PAGI::Test::Client;

sub _app_with_data {
    my ($routes) = @_;
    return compose(
        routes => $routes,
        lifespan => {
            startup => sub {
                my ($state, $scope) = @_;
                $state->{data} = MyApp::Data->new;
                return;
            },
            shutdown => sub {
                my ($state, $scope) = @_;
                delete $state->{data};
                return;
            },
        },
    )->to_app;
}

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

subtest 'application URL helpers own cross-component paths' => sub {
    is(MyApp::URL->people, '/person', 'people collection path');
    is(MyApp::URL->person('2'), '/person/2', 'person detail path');
    is(MyApp::URL->blogs('2'), '/person/2/blog', 'blog collection path');
    is(
        MyApp::URL->blog('2', '201'),
        '/person/2/blog/201',
        'blog detail path',
    );

    like(
        dies { MyApp::URL->person(undef) },
        qr/person_id must be a decimal identifier/,
        'undefined person identifier is rejected',
    );
    like(
        dies { MyApp::URL->blogs('not-a-number') },
        qr/person_id must be a decimal identifier/,
        'nonnumeric person identifier is rejected',
    );
    like(
        dies { MyApp::URL->blog('1', []) },
        qr/blog_id must be a decimal identifier/,
        'reference blog identifier is rejected',
    );
};

subtest 'application View owns the shared HTML document shell' => sub {
    my $html = MyApp::View->document('Fixture title', '    <h1>Body</h1>');
    like($html, qr{<!doctype html>}, 'document declares HTML');
    like($html, qr{<title>Fixture title</title>}, 'document uses its title');
    like($html, qr{href="/static/app.css"}, 'document links shared CSS');
    like($html, qr{    <h1>Body</h1>}, 'document includes owned body markup');
};

subtest 'Blogs owns local links, handler 404, catchall, and 405' => sub {
    my $app = _app_with_data([
        mount('/person/{person_id}/blog' => 'MyApp::Person::Blogs',
            constraints => { person_id => qr/\d+/ },
        ),
    ]);

    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;

        my $list = $client->get('/person/1/blog');
        is($list->status, 200, 'blog collection responds');
        like($list->text, qr{<h1>Blogs by Ada Lovelace</h1>},
            'blog collection identifies the inherited person');
        like($list->text, qr{href="/person/1/blog/101"},
            'local path_for generates the mounted blog detail path');

        my $detail = $client->get('/person/1/blog/101');
        is($detail->status, 200, 'blog detail responds');
        like($detail->text, qr{<h1>Notes on the Analytical Engine</h1>},
            'blog detail renders fixture content');
        like($detail->text, qr{href="/person/1"},
            'cross-component person link uses the application URL contract');

        my $missing = $client->get('/person/1/blog/999');
        is($missing->status, 404, 'unknown numeric blog is a handler 404');
        like($missing->text, qr{<h1>Blog not found</h1>},
            'unknown numeric blog uses the Blogs handler response');

        my $caught = $client->get('/person/1/blog/not/a/route');
        is($caught->status, 404, 'deeper unknown blog path is caught');
        like($caught->text, qr{<h1>Blogs section not found</h1>},
            'explicit Blogs catchall owns the deeper path');

        my $wrong_method = $client->post('/person/1/blog/101');
        is($wrong_method->status, 405, 'Blogs owns wrong-method outcome');
        is($wrong_method->header('Allow'), 'GET, HEAD',
            'Blogs 405 retains normalized Allow');
    });
};

subtest 'Person owns local routes and mounts Blogs as an application' => sub {
    my $app = _app_with_data([
        mount('/person' => 'MyApp::Person'),
    ]);

    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;

        my $list = $client->get('/person');
        is($list->status, 200, 'person collection responds');
        like($list->text, qr{<h1>People</h1>},
            'person collection renders its page');
        like($list->text, qr{href="/person/1"},
            'local path_for generates the mounted person detail path');
        like(
            $list->text,
            qr{Ada Lovelace</a> \x{2014} Mathematician},
            'person list decodes the em dash separator correctly',
        );

        my $detail = $client->get('/person/1');
        is($detail->status, 200, 'person detail responds');
        like($detail->text, qr{<h1>Ada Lovelace</h1>},
            'person detail renders fixture content');
        like($detail->text, qr{href="/person/1/blog"},
            'cross-component Blogs link uses the application URL contract');

        my $missing = $client->get('/person/999');
        is($missing->status, 404, 'unknown numeric person is a handler 404');
        like($missing->text, qr{<h1>Person not found</h1>},
            'unknown numeric person uses the Person handler response');

        my $blogs = $client->get('/person/1/blog');
        is($blogs->status, 200, 'opaque Blogs child is reachable');
        like($blogs->text, qr{<h1>Blogs by Ada Lovelace</h1>},
            'Blogs receives the inherited person path parameter');
    });
};

subtest 'Root composes lifespan, components, navigation, and outcomes' => sub {
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

        my $home = $client->get('/');
        is($home->status, 200, 'Root home responds');
        like($home->text, qr{<h1>My PAGI People</h1>},
            'Root home renders its page');
        like($home->text, qr{href="/person"},
            'Root-to-Person link uses MyApp::URL');

        my $people = $client->get('/person');
        is($people->status, 200, 'Person collection is mounted');
        like($people->text, qr{href="/person/1"},
            'Person local named route produces a working link');

        my $person = $client->get('/person/1');
        is($person->status, 200, 'Person detail is reachable');
        like($person->text, qr{href="/person/1/blog"},
            'Person-to-Blogs cross-component link works');

        my $blogs = $client->get('/person/1/blog');
        is($blogs->status, 200, 'Blogs collection is mounted');
        like($blogs->text, qr{href="/person/1/blog/101"},
            'Blogs local named route produces a working link');

        my $blog = $client->get('/person/1/blog/101');
        is($blog->status, 200, 'Blog detail is reachable');
        like($blog->text, qr{href="/person/1"},
            'Blogs-to-Person cross-component link works');

        my $person_missing = $client->get('/person/999');
        is($person_missing->status, 404,
            'matched missing person is a local handler 404');
        like($person_missing->text, qr{<h1>Person not found</h1>},
            'Person handler 404 remains untouched');

        my $blog_missing = $client->get('/person/1/blog/999');
        is($blog_missing->status, 404,
            'matched missing blog is a local handler 404');
        like($blog_missing->text, qr{<h1>Blog not found</h1>},
            'Blogs handler 404 remains untouched');

        my $blogs_catchall = $client->get('/person/1/blog/not/a/route');
        is($blogs_catchall->status, 404,
            'Blogs explicit catchall owns deeper paths');
        like($blogs_catchall->text,
            qr{<h1>Blogs section not found</h1>},
            'Blogs catchall body remains local');

        my $root_missing = $client->get('/outside');
        is($root_missing->status, 404, 'Root catchall handles root miss');
        like($root_missing->text, qr{<h1>Root page not found</h1>},
            'Root catchall is an ordinary branded route');

        my $child_none = $client->get('/person/1/unmatched');
        is($child_none->status, 404,
            'current opaque Person mount owns its routing NONE');
        is($child_none->text, 'Not Found',
            'GAP-02 evidence: generated child 404 cannot bubble to Root');

        my $wrong_method = $client->post('/person/1/blog/101');
        is($wrong_method->status, 405, 'child PARTIAL remains final');
        is($wrong_method->header('Allow'), 'GET, HEAD',
            'child 405 carries the normalized Allow header');

        my $css = $client->get('/static/app.css');
        is($css->status, 200, 'static stylesheet is mounted');
        is($css->header('Content-Type'), 'text/css',
            'file app selects the CSS media type');
        like($css->text, qr/\.page\s*\{/,
            'mounted stylesheet contains its recognizable page rule');

        my $static_missing = $client->get('/static/missing.css');
        is($static_missing->status, 404,
            'missing static asset remains owned by the file app');
        unlike($static_missing->text, qr{<h1>Root page not found</h1>},
            'native application 404 is not reinterpreted as Root decline');

        my $head = $client->head('/person/1');
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
