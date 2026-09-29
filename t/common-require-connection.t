use strict;
use warnings;
use Test2::V0;
use lib 'lib';
use PAGI::Common;
use PAGI::Test::ConnectionState;

# PAGI::Spec::Www: frameworks may rely on pagi.connection on a scope whose
# spec_version is 0.6 or later; an omitted spec_version means 0.1. Both the
# advertised version and the object's capabilities must hold.

sub scope_with {
    my (%opts) = @_;
    return {
        type => $opts{type} // 'websocket',
        (exists $opts{spec_version}
            ? (pagi => { spec_version => $opts{spec_version} }) : ()),
        'pagi.connection' => $opts{connection}
            // PAGI::Test::ConnectionState->new(websocket => 1),
    };
}

sub admit { PAGI::Common::require_connection($_[0], 'PAGI::WebSocket') }

subtest 'an omitted spec_version means 0.1 and is refused' => sub {
    like dies { admit(scope_with()) },
        qr/^PAGI::WebSocket requires PAGI::Spec::Www 0\.6 or later; server reports spec_version none \(0\.1\)/;
};

subtest 'an older advertised version is refused' => sub {
    like dies { admit(scope_with(spec_version => '0.5')) },
        qr/^PAGI::WebSocket requires PAGI::Spec::Www 0\.6 or later; server reports spec_version 0\.5/;
};

subtest 'an unreadable version is refused' => sub {
    like dies { admit(scope_with(spec_version => 'six')) },
        qr/server reports spec_version six/;
};

subtest '0.6 and later versions are accepted, compared as dotted numbers' => sub {
    for my $version (qw(0.6 0.10 1.0)) {
        my $scope = scope_with(spec_version => $version);
        is admit($scope), exact_ref($scope->{'pagi.connection'}),
            "$version returns the connection";
    }
};

subtest 'a 0.6 scope still needs every connection capability' => sub {
    like dies { admit(scope_with(spec_version => '0.6', connection => bless({}, 'Local::Empty'))) },
        qr/^PAGI::WebSocket requires pagi\.connection capabilities response_started, .*server reports spec_version 0\.6/;
};

done_testing;
