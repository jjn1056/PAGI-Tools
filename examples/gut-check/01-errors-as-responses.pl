#!/usr/bin/env perl
#
# Errors as responses: an error thrown from deep in the model becomes the
# right HTTP answer.
#
# Throw a PAGI::Exception::HTTP (what went wrong), and let one ErrorHandler
# catch entry decide how those errors look, as Starlette's
# exception_handlers={HTTPException: ...} does. Without the entry, the stock
# page answers with the right status and the message. A thrown response
# (die response('JSON', ..., status => 404)) also works with no entry at
# all: it answers itself. An ordinary bug is not an HTTP error: it gets the
# stock 500, and the server logs it.
#
# A path no route matches is not an error here: http_default answers it, so
# the entry never sees it. A wrong method is: the router raises its 405, and
# the entry passes on the error's headers, which carry the Allow a 405 must
# have (an entry answers in full, as a Starlette exception handler does).
#
# The Starlette version is in README.md.
#
# Run:  pagi-server --app examples/gut-check/01-errors-as-responses.pl --port 5000
# Try:  curl -i localhost:5000/notes/1
#       curl -i localhost:5000/notes/9      # 404, thrown from deep in the model
#       curl -i localhost:5000/boom         # an ordinary bug: the stock 500
#       curl -i localhost:5000/nope         # no route: the router's 404, same JSON shape

use v5.40;
use Future::AsyncAwait;
use PAGI::Exception::HTTP;
use PAGI::Tools qw(compose middleware response route);

my %NOTES = (1 => { id => 1, text => 'buy milk' });

# Deep in the "model": say what went wrong, not how it looks.
sub find_note ($id) {
    return $NOTES{$id} // PAGI::Exception::HTTP->throw(404, "no such note: $id");
}

async sub show ($request) {
    return response('JSON', find_note($request->path_param('id')));
}

async sub boom ($request) {
    die "an ordinary bug\n";
}

# The errors the app expects become JSON. A response with no status of its
# own takes the error's; its headers are passed on.
sub json_errors ($request, $error) {
    return response('JSON', { error => $error->message }, headers => $error->exception->headers);
}

compose(
    routes => [
        route('/notes/{id}' => \&show),
        route('/boom' => \&boom),
    ],
    http_default => sub ($request) { response('JSON', { error => 'Not Found' }, status => 404) },
    middleware => [middleware('ErrorHandler', catch => { 'PAGI::Exception::HTTP' => \&json_errors })],
);
