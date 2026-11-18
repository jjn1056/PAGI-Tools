#!/usr/bin/env perl
# Hello, World as an application object: a PAGI::App subclass writes call,
# and the server calls its to_app once, when it loads the file. The
# greeting is an attribute, read from GREETING on first use.
#
#   pagi-server --app examples/app/hello.pl --port 5000
#   curl -i http://localhost:5000/
#   GREETING=Bonjour pagi-server --app examples/app/hello.pl --port 5000

use v5.40;
use utf8;

package HelloApp {
    use v5.40;
    use utf8;
    use parent 'PAGI::App';
    use Future::AsyncAwait;
    use PAGI::Response::Text;
    use Class::Tiny { greeting => sub { $ENV{GREETING} // 'Hello' } };

    async sub call ($self, $scope, $receive, $send) {
        die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
        my $response = PAGI::Response::Text->new(content => $self->greeting . ", 🌍!\n");
        await $response->call($scope, $receive, $send);
    }
}

HelloApp->new;
