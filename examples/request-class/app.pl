#!/usr/bin/env perl
#
# An application's own Request class, set once by middleware.
#
#   - NotesApp::Request is a PAGI::Request subclass with two helpers this
#     application wants everywhere: $request->notes (the store built at
#     startup) and $request->page (the ?page= number, at least 1).
#   - middleware('RequestClass', class => ...) puts the class in the scope,
#     so every handler below it gets one: here a plain route, an
#     Endpoint::HTTP method, and a route inside a mount; also refuse and
#     deny/decline handlers, an ErrorHandler handler listed after it, and
#     Authentication backends. No handler is wrapped.
#   - For one or two helpers, a function that takes the request
#     (NoteStore->for_request($request), as in gut-check 02) is simpler;
#     a subclass pays off when many handlers use several helpers.
#
# Run:  pagi-server --app examples/request-class/app.pl --port 5000
# Try:  curl -i -X POST localhost:5000/notes -d '{"text":"buy milk"}'
#       curl -i 'localhost:5000/notes?page=1'
#       curl -i localhost:5000/notes/1
#       curl -i localhost:5000/admin/stats
#       curl -i -X DELETE localhost:5000/notes/1

use v5.40;
use Future::AsyncAwait;

package NotesApp::Store {
    use v5.40;

    sub new ($class) { bless { next => 1, notes => {} }, $class }
    sub add ($self, $text) { my $id = $self->{next}++; $self->{notes}{$id} = { id => $id, text => $text } }
    sub find ($self, $id) { $self->{notes}{$id} }
    sub remove ($self, $id) { delete $self->{notes}{$id} }
    sub count ($self) { scalar keys $self->{notes}->%* }

    # One page of notes, oldest first.
    sub page ($self, $page, $per_page) {
        my @ids = sort { $a <=> $b } keys $self->{notes}->%*;
        my $first = ($page - 1) * $per_page;
        return [ map { $self->{notes}{$_} } grep { defined } @ids[$first .. $first + $per_page - 1] ];
    }
}

package NotesApp::Request {
    use v5.40;
    use parent 'PAGI::Request';

    # The store built at startup, read through the read-only lifespan state.
    sub notes ($self) { $self->state->get('notes') }

    # The ?page= number: a positive whole number, else 1.
    sub page ($self) {
        my $page = $self->query_param('page') // '';
        return $page =~ /\A[1-9][0-9]{0,5}\z/ ? 0 + $page : 1;
    }
}

# One note: an Endpoint::HTTP class. Its methods get a NotesApp::Request too.
package NotesApp::Note {
    use v5.40;
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;
    use PAGI::Tools qw(response);

    async sub get ($self, $request) {
        my $note = $request->notes->find($request->path_param('id'))
            or return response('JSON', { error => 'no such note' }, status => 404);
        return response('JSON', $note);
    }

    async sub delete ($self, $request) {
        $request->notes->remove($request->path_param('id'))
            or return response('JSON', { error => 'no such note' }, status => 404);
        return response('Empty');
    }
}

package main;

use PAGI::Tools qw(compose endpoint middleware mount path_for response route);
use Types::Standard qw(Int);

my $PER_PAGE = 2;

# Plain routes: a bare handler gets a NotesApp::Request.
sub list_notes ($request) {
    return response('JSON', {
        page  => $request->page,
        notes => $request->notes->page($request->page, $PER_PAGE),
    });
}

async sub add_note ($request) {
    my $data = await $request->json;
    my $note = $request->notes->add($data->{text} // '');
    return response('JSON', $note,
        status  => 201,
        headers => [Location => path_for($request, 'note', { id => $note->{id} })],
    );
}

# Inside a mount: the class travels in the scope, so it applies here too.
sub stats ($request) {
    return response('JSON', { notes => $request->notes->count });
}

compose(
    middleware => [middleware('RequestClass', class => 'NotesApp::Request')],
    routes => [
        route('/notes' => \&list_notes, methods => ['GET']),
        route('/notes' => \&add_note,   methods => ['POST']),
        route('/notes/{id}' => endpoint('NotesApp::Note'), name => 'note', constraints => { id => Int }),
        mount('/admin', routes => [
            route('/stats' => \&stats),
        ]),
    ],
    lifespan => {
        startup => sub ($state, $scope) { $state->{notes} = NotesApp::Store->new },
    },
);
