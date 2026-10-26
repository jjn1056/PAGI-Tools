package NotesApp;
#
# Notes: class-based endpoints, and who decides how they are built.
#
# The caller names each class with endpoint() and gives it arguments. The
# class decides how it is built:
#   - a class without BUILD_APP gets a fresh object for every request (every
#     WebSocket connection), built with ->new(%args);
#   - a class whose BUILD_APP returns a coderef gets it called once per
#     request (or connection) with the request, to build the object that
#     answers it;
#   - a class whose BUILD_APP returns an object shares that one object
#     across every request.
# endpoint() loads each class itself.
# The route looks the same either way. The request or connection is never
# stored on the object: every handler receives it as an argument.
#
# Run:  pagi-server -I examples/endpoint-lifecycle/lib \
#           --app examples/endpoint-lifecycle/lib/NotesApp.pm --port 5000
# Try:  curl -i -H 'X-User: alice' -H 'Content-Type: application/json' \
#            -d '{"text":"buy milk"}' localhost:5000/notes
#       curl -i localhost:5000/notes
#       curl -i localhost:5000/notes/1
#       curl -i -X PUT localhost:5000/notes          # 405, Allow from the class
#       curl -i localhost:5000/health                # hits counts up: one shared object

use v5.40;
use parent 'PAGI::App::Compose';

use NotesApp::Store;
use PAGI::Tools qw(endpoint route websocket);
use Types::Standard qw(Int);

sub routes ($self) {
    return [
        route('/notes'      => endpoint('NotesApp::Notes', page_size => 50), name => 'notes'),
        route('/notes/{id}' => endpoint('NotesApp::Note'), name => 'note', constraints => { id => Int }),
        websocket('/watch'  => endpoint('NotesApp::Watch', greeting => 'welcome')),
        route('/health'     => endpoint('NotesApp::Health', version => '1.0')),
    ];
}

sub on_startup ($self, $state, $scope) { $state->{notes} = NotesApp::Store->new }

__PACKAGE__->run_if_script;
