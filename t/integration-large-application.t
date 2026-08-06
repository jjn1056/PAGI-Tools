use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../examples/15-large-application/lib";

use MyApp::Data;
use MyApp::URL;
use MyApp::View;

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

done_testing;
