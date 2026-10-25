#!/usr/bin/env perl
#
# Notes edited from plain HTML forms. A form can only GET or POST, so each
# one says the method it means in its action URL -- ?_method=PUT or
# ?_method=DELETE -- and MethodOverride turns the POST into that method
# before routing. It reads the header and the query string, never the body:
# the rename form's text reaches the PUT route untouched, and the route reads
# it with form_params as usual. The same application in Starlette is app.py.
#
# Run:  pagi-server --app examples/method-override/app.pl --port 5000
# Then open http://localhost:5000/notes, or:
#       curl -i localhost:5000/notes -d text=milk                          # 303: note 1
#       curl -i 'localhost:5000/notes/1?_method=PUT' -d text=oat+milk      # 303: renamed
#       curl -i -X POST localhost:5000/notes/1 -H 'X-HTTP-Method-Override: DELETE'   # 303: deleted
#       curl -i localhost:5000/notes/1 -d _method=DELETE                   # 405: a body field is not an override

use v5.40;
use Future::AsyncAwait;
use PAGI::Tools qw(compose middleware response route);

my %NOTES;
my $next_id = 1;

sub html ($text) { $text =~ s/([&<>"])/'&#' . ord($1) . ';'/ger }

# Each note has a rename form (?_method=PUT) and a delete form
# (?_method=DELETE); the page ends with a plain POST form to add one.
async sub list_notes ($request) {
    my $items = join '', map {
        my $text = html($NOTES{$_});
        qq{<li><form method="post" action="/notes/$_?_method=PUT"><input name="text" value="$text">}
            . qq{<button>Rename</button></form>}
            . qq{<form method="post" action="/notes/$_?_method=DELETE"><button>Delete</button></form></li>}
    } sort { $a <=> $b } keys %NOTES;
    return response('HTML', qq{<ul>$items</ul>}
        . qq{<form method="post" action="/notes"><input name="text"><button>Add</button></form>});
}

async sub add_note ($request) {
    $NOTES{ $next_id++ } = (await $request->form_params)->get('text') // '';
    return response('Redirect', '/notes', status => 303);
}

# Reached as PUT: the form was POSTed to /notes/{id}?_method=PUT, and its
# body is read here, where MethodOverride left it.
async sub rename_note ($request) {
    my $id = $request->path_param('id');
    return response('Text', 'No such note.', status => 404) unless exists $NOTES{$id};
    $NOTES{$id} = (await $request->form_params)->get('text') // '';
    return response('Redirect', '/notes', status => 303);
}

async sub delete_note ($request) {
    delete $NOTES{ $request->path_param('id') }
        // return response('Text', 'No such note.', status => 404);
    return response('Redirect', '/notes', status => 303);
}

compose(
    routes => [
        route('/notes' => \&list_notes),
        route('/notes' => \&add_note, methods => ['POST']),
        route('/notes/{id}' => \&rename_note, methods => ['PUT']),
        route('/notes/{id}' => \&delete_note, methods => ['DELETE']),
    ],
    middleware => [middleware('MethodOverride')],
);
