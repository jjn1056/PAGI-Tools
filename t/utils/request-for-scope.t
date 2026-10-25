use strict;
use warnings;
use Test2::V0;
use Future;
use lib 'lib';
use PAGI::Utils ();

# PAGI::Utils::request_for_scope: the Request this scope's application code
# receives, built by the scope key pagi.request.factory (set by
# RequestClass) or a plain PAGI::Request.

{
    package Local::AppRequest;
    use parent 'PAGI::Request';
}

my $receive = sub { Future->done({ type => 'http.disconnect' }) };

sub scope_with {
    my (%extra) = @_;
    return { type => 'http', method => 'GET', path => '/', headers => [], %extra };
}

sub request_for {
    my ($scope) = @_;
    return PAGI::Utils::request_for_scope($scope, $receive);
}

subtest 'exported on request and in :all' => sub {
    package Local::Importer {
        use PAGI::Utils qw(request_for_scope);
        main::is(ref(request_for_scope({ type => 'http', headers => [] }, $receive)), 'PAGI::Request', 'imported by name');
    }
    ok((grep { $_ eq 'request_for_scope' } @{ $PAGI::Utils::EXPORT_TAGS{all} }), 'in :all');
};

subtest 'no factory gives a plain PAGI::Request' => sub {
    is(ref(request_for(scope_with())), 'PAGI::Request', 'an absent key');
    is(ref(request_for(scope_with('pagi.request.factory' => undef))), 'PAGI::Request',
        'an undef key');
};

subtest 'a factory builds its class from the exact scope and receive' => sub {
    my @calls;
    my $scope = scope_with('pagi.request.factory' => sub {
        push @calls, [@_];
        return Local::AppRequest->new(@_);
    });
    is(ref(request_for($scope)), 'Local::AppRequest', 'the factory class');
    is(scalar @calls, 1, 'the factory runs once');
    ok($calls[0][0] == $scope && $calls[0][1] == $receive,
        'with exactly the scope and receive given');
    is(scalar @{ $calls[0] }, 2, 'and nothing else');
};

subtest 'a bad key or a bad factory result croaks naming the key' => sub {
    like(dies { request_for(scope_with('pagi.request.factory' => 'MyApp::Request')) },
        qr/\Ascope key 'pagi\.request\.factory' must be a coderef at /,
        'a key that is not a coderef');
    like(dies { request_for(scope_with('pagi.request.factory' => sub { bless {}, 'Local::NotARequest' })) },
        qr/\Ascope key 'pagi\.request\.factory' must return a PAGI::Request instance or subclass at /,
        'a factory that returns something else');
    like(dies { request_for(scope_with('pagi.request.factory' => sub { Future->done(Local::AppRequest->new(@_)) })) },
        qr/\Ascope key 'pagi\.request\.factory' must return a PAGI::Request instance or subclass at /,
        'a factory that returns a Future, as an async sub would');
};

done_testing;
