#!/usr/bin/env perl
#
# One notes resource for browsers, htmx and API clients.
#
#   - Browsers get HTML pages and post a form; API clients get JSON and post
#     JSON. The ContentNegotiation middleware picks the representation from
#     Accept, refuses what neither can satisfy, and sends Vary: Accept on
#     everything; handlers only say what each representation is.
#   - With htmx, the same URLs answer a fragment instead of the whole page
#     when the request says HX-Request, and say so with Vary: HX-Request.
#   - Negotiation is declared on the /notes mount only: /health answers in
#     one type and stays out of it.
#
# Run:  pagi-server --app examples/content-negotiation/app.pl --port 5000
# Try:  open http://localhost:5000/notes in a browser and add a few notes
#       curl -i -H 'Accept: application/json' localhost:5000/notes
#       curl -i -H 'Accept: application/json' -H 'Content-Type: application/json' \
#            -d '{"text":"buy milk"}' localhost:5000/notes
#       curl -i -H 'HX-Request: true' localhost:5000/notes        # the fragment
#       curl -i -H 'Accept: image/png' localhost:5000/notes       # 406
#       curl -i -H 'Accept: image/png' localhost:5000/health      # 200, not negotiated

use v5.40;
use Future::AsyncAwait;

package NoteStore {
    use v5.40;

    sub new ($class) { bless { next => 1, notes => {} }, $class }
    sub all ($self) { [ map { $self->{notes}{$_} } sort { $a <=> $b } keys $self->{notes}->%* ] }
    sub find ($self, $id) { $self->{notes}{$id} }
    sub add ($self, $text) { my $id = $self->{next}++; $self->{notes}{$id} = { id => $id, text => $text } }

    sub for_request ($class, $request) { $request->state->get('notes') }
}

package main;

use PAGI::Tools qw(compose middleware mount negotiated_type path_for respond_to response route);
use PAGI::Exception::RequestBody;
use Types::Standard qw(Int);

sub esc ($text) { $text =~ s/([&<>"'])/'&#' . ord($1) . ';'/ger }

sub page ($title, $body, %opts) {
    return response('HTML', join('',
        '<!doctype html><title>', esc($title), '</title>',
        '<script src="https://unpkg.com/htmx.org@2.0.4"></script>',
        '<h1>', esc($title), '</h1>', $body,
    ), %opts);
}

sub note_list ($request, $notes) {
    return join '', '<ul id="notes">',
        (map { '<li><a href="' . path_for($request, 'note', { id => $_->{id} }) . '">'
            . esc($_->{text}) . '</a></li>' } @$notes),
        '</ul>';
}

# The list's HTML depends on HX-Request as well as Accept: htmx swaps in the
# list alone, a browser gets the whole page. Both say so, so a cache keeps
# them apart (the middleware adds Accept to this Vary).
sub list_html ($request, $notes) {
    my @vary = (headers => [Vary => 'HX-Request']);
    return response('HTML', note_list($request, $notes), @vary) if $request->header('HX-Request');
    my $form = '<form method="post" action="' . path_for($request, 'notes') . '"'
        . ' hx-post="' . path_for($request, 'notes') . '" hx-target="#notes" hx-swap="outerHTML">'
        . '<input name="text" required><button>Add</button></form>';
    return page('Notes', note_list($request, $notes) . $form, @vary);
}

async sub list ($request) {
    my $notes = NoteStore->for_request($request)->all;
    return respond_to($request,
        html => sub { list_html($request, $notes) },
        json => sub { response('JSON', $notes) },
    );
}

async sub show ($request) {
    # The same choice, read directly, where an if reads better than branches.
    # The 404 is returned, not thrown: a returned answer gets the middleware's
    # Vary: Accept, a thrown one goes straight to the error handler.
    my $note = NoteStore->for_request($request)->find($request->path_param('id'))
        or return negotiated_type($request) eq 'json'
            ? response('JSON', { error => 'no such note' }, status => 404)
            : page('Not found', '<p>No such note.</p>', status => 404);

    return respond_to($request,
        html => sub { page('Note', '<p>' . esc($note->{text}) . '</p>') },
        json => sub { response('JSON', $note) },
    );
}

async sub create ($request) {
    # The body's type decides how to read it (input); Accept decides the
    # answer (output). They are separate questions.
    # Anything but JSON or a form is the client's 415, answered like any other
    # body error.
    my $data = $request->is_json ? await $request->json
             : $request->is_form ? (await $request->form_params)->as_hashref
             : PAGI::Exception::RequestBody->throw(
                   status_code => 415,
                   reason      => 'unsupported_media_type',
                   message     => 'The request body must be JSON or a form.',
               );
    my $text = ref $data eq 'HASH' ? $data->{text} : undef;
    return response('Text', 'A note needs text.', status => 400)
        unless defined $text && !ref $text && length $text;

    my $store = NoteStore->for_request($request);
    my $note  = $store->add($text);
    my $url   = path_for($request, 'note', { id => $note->{id} });
    return respond_to($request,
        # htmx posted the form: answer the new list in place. A plain form
        # post is redirected to the list, so a reload does not post again.
        html => sub {
            $request->header('HX-Request')
                ? list_html($request, $store->all)
                : response('Redirect', path_for($request, 'notes'), status => 303);
        },
        json => sub { response('JSON', $note, status => 201, headers => [Location => $url]) },
    );
}

compose(
    routes => [
        route('/health' => sub ($request) { response('Text', 'ok') }),
        mount('/notes',
            routes => [
                route('/'     => \&list,   name => 'notes'),
                route('/'     => \&create, methods => 'POST'),
                route('/{id}' => \&show,   name => 'note', constraints => { id => Int }),
            ],
            middleware => [
                # The types every route here can answer with, most preferred
                # first (a browser sending */* gets HTML). The refusal is the
                # app's own: an RFC 9457 problem instead of the stock text.
                middleware('ContentNegotiation',
                    supported_types => ['html', 'json'],
                    refuse => response('Problem', {
                        type   => '/problems/not-acceptable',
                        title  => 'Not Acceptable',
                        status => 406,
                        detail => 'This resource is available as text/html or application/json.',
                    }),
                ),
            ],
        ),
    ],
    lifespan => {
        startup => sub ($state, $scope) { $state->{notes} = NoteStore->new },
    },
);
