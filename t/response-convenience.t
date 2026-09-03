use strict;
use warnings;
use Test2::V0;
use PAGI::Response qw(
    :all
);

subtest 'facade exports are opt-in and map to fixed first-party classes' => sub {
    is([sort @PAGI::Response::EXPORT_OK], [sort qw(
        response text_response html_response json_response problem_response
        redirect_response empty_response file_response stream_response ndjson_response
    )], ':all contains exactly the ten fixed facade names');
    is([sort @{$PAGI::Response::EXPORT_TAGS{all}}], [sort @PAGI::Response::EXPORT_OK],
        ':all tag maps to every and only facade factory');
    my $default = eval q{
        package T::NoDefaultResponseImports;
        use PAGI::Response;
        defined &response ? 1 : 0;
    };
    is($default, 0, 'PAGI::Response exports no default factory');

    my $unknown = eval q{
        package T::UnknownResponseImport;
        use PAGI::Response qw(not_a_response_factory);
        1;
    };
    ok(!$unknown, 'unknown facade import fails');
    like($@, qr/not_a_response_factory/, 'unknown import names the rejected factory');

    is(ref(response('bytes')), 'PAGI::Response', 'response has exact base class identity');
    is(ref(text_response('hello')), 'PAGI::Response::Text', 'text_response has exact class identity');
    is(ref(html_response('<b>x</b>')), 'PAGI::Response::HTML', 'html_response has exact class identity');
    is(ref(json_response({ ok => \1 })), 'PAGI::Response::JSON', 'json_response has exact class identity');
    is(ref(problem_response({ title => 'Nope' })), 'PAGI::Response::Problem', 'problem_response has exact class identity');
    is(ref(redirect_response('/next')), 'PAGI::Response::Redirect', 'redirect_response has exact class identity');
    is(ref(empty_response(status => 204)), 'PAGI::Response::Empty', 'empty_response has exact class identity');
    ok(defined &file_response, 'facade has the deferred fixed File factory');
    ok(defined &stream_response, 'facade has the deferred fixed Stream factory');
};

subtest 'each concrete class optionally exports only its matching factory' => sub {
    my $text = eval q{
        package T::TextFactory;
        use PAGI::Response::Text qw(text_response);
        text_response('hello');
    };
    isa_ok($text, ['PAGI::Response::Text']);

    my $html = eval q{
        package T::HTMLFactory;
        use PAGI::Response::HTML qw(html_response);
        html_response('<b>x</b>');
    };
    isa_ok($html, ['PAGI::Response::HTML']);

    my @subclass_factories = (
        ['PAGI::Response::JSON', 'json_response', '{ ok => \1 }'],
        ['PAGI::Response::Problem', 'problem_response', q{{ title => 'Nope' }}],
        ['PAGI::Response::Redirect', 'redirect_response', q{'/next'}],
        ['PAGI::Response::Empty', 'empty_response', q{}],
    );
    for my $factory (@subclass_factories) {
        my ($class, $name, $arguments) = @$factory;
        my $value = eval "package T::${name}Factory; use $class qw($name); $name($arguments);";
        is(ref($value), $class, "$class optionally exports $name with exact identity");
    }
};

done_testing;
