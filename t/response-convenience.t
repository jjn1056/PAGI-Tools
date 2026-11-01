use strict;
use warnings;
use Test2::V0;
use PAGI::Response ();

subtest 'PAGI::Response exports one builder and one predicate, only on request' => sub {
    # response('Name', ...) is the one builder; status_forbids_body is a
    # predicate, not another way to build a response.
    is([sort keys %{ PAGI::Response->_exports }], ['response', 'status_forbids_body'], 'the exports');
    is([grep { /_response$/ } keys %{ PAGI::Response->_exports }], [], 'no NAME_response factory');
    my $all = eval q{
        package T::AllResponseImports;
        use PAGI::Response qw(:all);
        no strict 'refs';
        [grep { defined &{"T::AllResponseImports::$_"} } qw(response status_forbids_body)];
    };
    is($all, ['response', 'status_forbids_body'], ':all is both');
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
        (my $package = "T::From::$class") =~ s/::/_/g;
        ok(!eval "package $package; use $class qw(response); 1", "$class exports nothing");
        like($@, qr/\A\Q$class\E exports nothing; import from PAGI::Response at /,
            'and points at PAGI::Response');
    }
};

done_testing;
