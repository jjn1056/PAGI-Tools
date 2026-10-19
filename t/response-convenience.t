use strict;
use warnings;
use Test2::V0;
use PAGI::Response ();

subtest 'PAGI::Response exports one builder and one predicate, only on request' => sub {
    # response('Name', ...) is the one builder; status_forbids_body is a
    # predicate, not another way to build a response.
    is([@PAGI::Response::EXPORT_OK], ['response', 'status_forbids_body'], 'the exports');
    is([@{$PAGI::Response::EXPORT_TAGS{all}}], ['response', 'status_forbids_body'], ':all is both');
    is([grep { /_response$/ } @PAGI::Response::EXPORT_OK], [], 'no NAME_response factory');
    my $default = eval q{
        package T::NoDefaultResponseImports;
        use PAGI::Response;
        defined &response ? 1 : 0;
    };
    is($default, 0, 'nothing is exported by default');
    my $unknown = eval q{
        package T::RemovedFactoryImport;
        use PAGI::Response qw(json_response);
        1;
    };
    ok(!$unknown, 'a removed factory cannot be imported');
};

subtest 'Response subclasses export nothing' => sub {
    for my $class (map { "PAGI::Response::$_" } qw(Text HTML JSON Problem Redirect Empty File Stream NDJSON)) {
        (my $file = "$class.pm") =~ s{::}{/}g;
        require $file;
        no strict 'refs';
        is([@{"${class}::EXPORT_OK"}], [], "$class exports nothing");
    }
};

done_testing;
