use strict;
use warnings;
use Test2::V0;
use PAGI::Response;

{
    package T::IdentityResponse;
    use parent -norequire, 'PAGI::Response';
    sub default_content_type { 'application/x-identity' }
    sub render { $_[1] }
}

my $res = T::IdentityResponse->new('bytes');
isa_ok $res, ['PAGI::Response'], 'subclass inherits the base value contract';
is $res->content_type, 'application/x-identity', 'subclass default applies';
is $res->body, 'bytes', 'subclass render supplies the body';
done_testing;
