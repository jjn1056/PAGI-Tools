use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Test::Client;

# PAGI::Tools re-exports toolkit functions by name: each is its source
# module's own sub, so declaration-package rules such as &Name constraint
# providers see the importing package.

my %SOURCE = (
    compose               => 'PAGI::Compose',
    response              => 'PAGI::Response',
    router                => 'PAGI::Routing',
    route                 => 'PAGI::Routing',
    websocket             => 'PAGI::Routing',
    sse                   => 'PAGI::Routing',
    mount                 => 'PAGI::Routing',
    middleware            => 'PAGI::Routing',
    request_response      => 'PAGI::Routing',
    endpoint              => 'PAGI::Routing',
    url                   => 'PAGI::Routing::URL',
    path_for              => 'PAGI::Routing::URL',
    url_for               => 'PAGI::Routing::URL',
    openapi               => 'PAGI::Routing::OpenAPI',
    error_context         => 'PAGI::ErrorContext',
    http_connection       => 'PAGI::HTTPConnection',
    app_state             => 'PAGI::State',
    stash                 => 'PAGI::Stash',
    session               => 'PAGI::Session',
    content_negotiation   => 'PAGI::ContentNegotiation',
    negotiated_type       => 'PAGI::ContentNegotiation',
    respond_to            => 'PAGI::ContentNegotiation',
    clone_scope           => 'PAGI::Utils::Middleware',
    wrap_send             => 'PAGI::Utils::Middleware',
    wrap_receive          => 'PAGI::Utils::Middleware',
    wrap_response_headers => 'PAGI::Utils::Middleware',
    record_receive        => 'PAGI::Utils::Middleware',
);

{
    package Local::Facade::All;
    use PAGI::Tools qw(:all);
}
{
    package Local::Facade::Routes;
    use PAGI::Tools qw(:routes);
}
{
    package Local::Facade::Urls;
    use PAGI::Tools qw(:urls);
}

sub installed {
    my ($package) = @_;
    no strict 'refs';
    return [sort grep { defined &{"${package}::$_"} } keys %{"${package}::"}];
}

subtest 'each name is its source module\'s own sub' => sub {
    for my $name (sort keys %SOURCE) {
        ok(\&{"Local::Facade::All::$name"} == \&{"$SOURCE{$name}::$name"},
            "$name is $SOURCE{$name}::$name");
    }
};

subtest 'an unknown name dies at compile time' => sub {
    like(dies { eval q{ package Local::Facade::Unknown; use PAGI::Tools qw(nope); 1 } or die $@ },
        qr/\A"nope" is not exported by PAGI::Tools at /);
};

subtest 'a &Name provider resolves in the importing package' => sub {
    my $app = eval q{
        package Local::Facade::Provider;
        use PAGI::Tools qw(compose response route);
        sub Int { qr/\A[0-9]+\z/ }
        compose(routes => [route('/notes/{id:&Int}' => sub {
            my ($request) = @_;
            response('Text', 'note ' . $request->path_param('id'));
        })]);
    } or die $@;
    my $client = PAGI::Test::Client->new(app => $app);
    is($client->get('/notes/7')->text, 'note 7', 'a matching id');
    is($client->get('/notes/x')->status, 404, 'Local::Facade::Provider::Int rejects the rest');
};

subtest 'the tags hold exactly the listed names' => sub {
    is(installed('Local::Facade::Routes'), [sort qw(router route websocket sse mount)], ':routes');
    is(installed('Local::Facade::Urls'), [sort qw(url path_for url_for)], ':urls');
    is(installed('Local::Facade::All'), [sort keys %SOURCE], ':all');
};

done_testing;
