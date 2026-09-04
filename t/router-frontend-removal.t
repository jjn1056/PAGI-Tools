use strict;
use warnings;
use Test2::V0;

my @removed = qw(
    PAGI/App/Router.pm
    PAGI/App/Router/Builder.pm
    PAGI/App/Router/Materializer.pm
    PAGI/Endpoint/Router.pm
    PAGI/Endpoint/Router/Builder.pm
);

for my $module (@removed) {
    ok !-e "lib/$module", "$module is absent";
    local @INC = ('lib');
    my $loaded = eval { require $module; 1 };
    ok !$loaded, "$module cannot load from source";
}

done_testing;
