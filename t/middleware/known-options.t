use strict;
use warnings;
use Test2::V0;
use lib 'lib';
use PAGI::Middleware;

my %required = (
    Authentication     => [backend => sub {}],
    ContentNegotiation => [supported_types => ['text/plain']],
    Rewrite            => [rules => []],
    Static             => [root => '.'],
    TrustedHosts       => [hosts => ['example.com']],
    XSendfile          => [type => 'X-Sendfile'],
);
# Options _init reads only to reject them with a message of their own.
my %rejected = (
    CSRF               => ['enforce', 'secret'],
    ContentNegotiation => ['strict', 'default_type'],
    RateLimit          => ['backend'],
);
my @classes = qw(AccessLog Authentication ConditionalGet ContentLength ContentNegotiation
    Cookie CORS CSRF Debug ErrorHandler ETag GZip Head Healthcheck HTTPSRedirect Lint
    Maintenance MethodOverride RateLimit RequestId ReverseProxy Rewrite Runtime
    SecurityHeaders Session SSE::Retry Static TrustedHosts XSendfile);

for my $name (@classes) {
    my $class = "PAGI::Middleware::$name";
    subtest $name => sub {
        eval "require $class; 1" or die $@;
        like dies { $class->new(@{ $required{$name} // [] }, bogus_option => 1) },
            qr/\Q$name has unknown option 'bogus_option'\E/, 'an unknown option dies';
        ok lives { $class->new(@{ $required{$name} // [] }) }, 'its required options suffice';

        # Every key _init reads is in its accepted list: guards against drift.
        (my $file = "$class.pm") =~ s{::}{/}g;
        open my $fh, '<', $INC{$file} or die $!;
        my $source = do { local $/; <$fh> };
        my ($list) = $source =~ /_reject_unknown_options\(\s*'\Q$name\E',\s*\$config(?:,\s*qw\(([^)]*)\))?\s*\)/;
        ok defined($list) || $source =~ /_reject_unknown_options\(\s*'\Q$name\E',\s*\$config\s*\)/,
            'it checks its options';
        my %accepted = map { $_ => 1 } split(' ', $list // ''), @{ $rejected{$name} // [] };
        my %read = map { $_ => 1 } $source =~ /\$config->\{(\w+)\}/g;
        is [grep { !$accepted{$_} } sort keys %read], [], 'every option it reads is accepted';
    };
}

subtest 'a third-party subclass is not checked' => sub {
    package Local::Plain { use parent -norequire, 'PAGI::Middleware' }
    ok lives { Local::Plain->new(anything => 1) }, 'the base class does not check options';
};

subtest 'a removed option keeps its own message' => sub {
    require PAGI::Middleware::CSRF;
    like dies { PAGI::Middleware::CSRF->new(enforce => 1) },
        qr/CSRF 'enforce' was removed/;
};

done_testing;
