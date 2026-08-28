use strict;
use warnings;
use Test2::V0;
use PAGI::Response qw(
    :all
);

subtest 'facade exports are opt-in and map to fixed first-party classes' => sub {
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

    isa_ok(response('bytes'), ['PAGI::Response']);
    isa_ok(text_response('hello'), ['PAGI::Response::Text']);
    isa_ok(html_response('<b>x</b>'), ['PAGI::Response::HTML']);
    isa_ok(json_response({ ok => \1 }), ['PAGI::Response::JSON']);
    isa_ok(problem_response({ title => 'Nope' }), ['PAGI::Response::Problem']);
    isa_ok(redirect_response('/next'), ['PAGI::Response::Redirect']);
    isa_ok(empty_response(status => 204), ['PAGI::Response::Empty']);
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
};

done_testing;
