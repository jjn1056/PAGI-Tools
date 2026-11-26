#!/usr/bin/env perl
# HTTP errors thrown from deep in an app, answered by
# PAGI::Middleware::ErrorHandler, with a subclass answering the app's own
# exception too.
#
#   pagi-server --app examples/exceptions/notes.pl --port 5000
#   curl -i http://localhost:5000/notes/1    # 200 {"id":1,"text":"buy milk"}
#   curl -i http://localhost:5000/notes/2    # 410 JSON: the subclass's answer
#   curl -i http://localhost:5000/notes/3    # 503 with Retry-After; the server logs the cause
#   curl -i http://localhost:5000/notes/9    # 404 No note 9.
#   curl -i http://localhost:5000/other      # 404 Not Found

use v5.40;
use Future::AsyncAwait;
use Scalar::Util ();
use PAGI::Exception::HTTP;
use PAGI::Middleware::ErrorHandler;
use PAGI::Response::JSON;

# The app's own exception: a note that existed and was deleted.
package Notes::Gone {
    sub new ($class, $id) { bless { id => $id }, $class }
    sub id ($self) { $self->{id} }
}

# The error handler, answering Notes::Gone as well as HTTP errors.
package Notes::Errors {
    use parent -norequire, 'PAGI::Middleware::ErrorHandler';

    sub response_for ($self, $error, $scope) {
        return PAGI::Response::JSON->new(status => 410, content => { error => 'note ' . $error->id . ' was deleted' })
            if Scalar::Util::blessed($error) && $error->isa('Notes::Gone');
        return $self->SUPER::response_for($error, $scope);
    }
}

my %NOTES   = (1 => { id => 1, text => 'buy milk' });
my %DELETED = (2 => 1);

# Deep in the model: no request, no response, just what went wrong.
sub find_note ($id) {
    die Notes::Gone->new($id) if $DELETED{$id};
    PAGI::Exception::HTTP->throw(status_code => 503, client_message => 'Notes are resting; try again soon.',
        headers => [['retry-after', '30']], cause => 'database: connection refused')
        if $id == 3;
    return $NOTES{$id} // PAGI::Exception::HTTP->throw(status_code => 404, client_message => "No note $id.");
}

my $app = async sub ($scope, $receive, $send) {
    die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
    my ($id) = $scope->{path} =~ m{\A/notes/(\d+)\z}
        or PAGI::Exception::HTTP->throw(status_code => 404);
    await PAGI::Response::JSON->new(content => find_note($id))->call($scope, $receive, $send);
};

Notes::Errors->wrap($app);
