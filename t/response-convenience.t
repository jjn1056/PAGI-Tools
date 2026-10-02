use strict;
use warnings;
use Test2::V0;
use PAGI::Response ();

subtest 'PAGI::Response exports only the builder, and only on request' => sub {
    is([@PAGI::Response::EXPORT_OK], ['response'], 'response is the only export');
    is([@{$PAGI::Response::EXPORT_TAGS{all}}], ['response'], ':all is the builder');
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
