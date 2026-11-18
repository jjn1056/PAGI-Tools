# Hello, World as a module you point the server at: a PAGI::App::Runnable
# ends with run_if_script in place of 1;, so loading the file gives the
# server the application, and running it with Perl says how to serve it.
# The greeting is an attribute, read from GREETING on first use.
#
#   cd examples/runnable
#   pagi-server -Ilib --app lib/Hello.pm --port 5000
#   curl -i http://localhost:5000/
#   GREETING=Bonjour pagi-server -Ilib --app lib/Hello.pm --port 5000
#   perl lib/Hello.pm      # dies, saying how to serve it

package Hello;
use v5.40;
use utf8;
use parent 'PAGI::App::Runnable';
use Future::AsyncAwait;
use PAGI::Response::Text;
use Class::Tiny { greeting => sub { $ENV{GREETING} // 'Hello' } };

async sub call ($self, $scope, $receive, $send) {
    die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
    my $response = PAGI::Response::Text->new(content => $self->greeting . ", 🌍!\n");
    await $response->call($scope, $receive, $send);
}

__PACKAGE__->run_if_script;    # in place of 1;
