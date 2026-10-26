#!/usr/bin/env perl
#
# An internal tool: a task board for a small team. The everyday HTML
# workflow every web framework is judged on: pages from templates, a form
# that re-renders with its errors, redirect after POST, a flash message on
# the next page, CSRF on every form, errors answered in one place, a
# stylesheet from a static directory.
#
# PAGI-Tools ships no template engine, flash or validation; this app shows
# what each costs on top of it: Template Toolkit for the pages, a two-line
# flash on the session, hand-written validation. The same application in
# Flask is in this example's README.
#
# Run:  pagi-server --app examples/internal-tool/app.pl --port 5000
# Then open http://localhost:5000/

use v5.40;
use utf8;
use Future::AsyncAwait;
use Template;
use PAGI::App::File;
use PAGI::CSRF qw(csrf);
use PAGI::Session qw(session);
use PAGI::Tools qw(app_state compose middleware mount path_for response route);
use PAGI::Utils qw(app_path);

my $tt = Template->new(INCLUDE_PATH => app_path('templates'), ENCODING => 'utf8');

# Render a template to an HTML Response. Every page gets the CSRF token,
# the flash message set by the previous request, and a link builder.
sub page ($request, $template, %vars) {
    my $flash = session($request)->get('flash', undef);
    session($request)->delete('flash') if defined $flash;
    $tt->process($template, {
        %vars,
        csrf_token => csrf($request)->token,
        flash      => $flash,
        url        => sub ($name, @args) { path_for($request, $name, @args) },
    }, \my $html) or die $tt->error;
    return response('HTML', $html, status => $vars{status} // 200);
}

sub flash ($request, $message) { session($request)->set(flash => $message) }

sub tasks ($request) { app_state($request)->get('board') }

sub validate ($form) {
    my %errors;
    my $title = $form->get('title') // '';
    $title =~ s/^\s+|\s+$//g;
    $errors{title} = 'A title is required.' if $title eq '';
    $errors{title} = 'Keep the title under 80 characters.' if length $title > 80;
    my $due = $form->get('due') // '';
    $errors{due} = 'Use YYYY-MM-DD.' if $due ne '' && $due !~ /\A\d{4}-\d{2}-\d{2}\z/;
    return ({ title => $title, due => $due }, \%errors);
}

# The board. It raises its own errors; the routes do not check for them.
package TaskBoard::TitleTaken {
    sub new ($class, %fields) { return bless {%fields}, $class }
    sub title ($self) { return $self->{title} }
}
package TaskBoard::NoSuchTask {
    sub new ($class) { return bless {}, $class }
}

sub add_task ($board, $values) {
    die TaskBoard::TitleTaken->new(title => $values->{title})
        if grep { lc($_->{title}) eq lc($values->{title}) } @{ $board->{list} };
    push @{ $board->{list} }, { id => $board->{next}++, %$values, done => 0 };
}

sub find_task ($board, $id) {
    my ($task) = grep { $_->{id} == $id } @{ $board->{list} };
    return $task // die TaskBoard::NoSuchTask->new;
}

async sub index ($request) {
    return page($request, 'index.tt', tasks => tasks($request)->{list}, form => {}, errors => {});
}

async sub create ($request) {
    my $form = await $request->form_params;
    my ($values, $errors) = validate($form);
    return page($request, 'index.tt', tasks => tasks($request)->{list},
        form => $values, errors => $errors, status => 422)
        if %$errors;

    add_task(tasks($request), $values);
    flash($request, "Added \"$values->{title}\".");
    return response('Redirect', path_for($request, 'index'), status => 303);
}

async sub toggle ($request) {
    my $task = find_task(tasks($request), $request->path_param('id'));
    $task->{done} = !$task->{done} || 0;
    flash($request, $task->{done} ? "Done: $task->{title}." : "Reopened: $task->{title}.");
    return response('Redirect', path_for($request, 'index'), status => 303);
}

async sub remove ($request) {
    my $board = tasks($request);
    my $task  = find_task($board, $request->path_param('id'));
    @{ $board->{list} } = grep { $_ != $task } @{ $board->{list} };
    flash($request, 'Deleted.');
    return response('Redirect', path_for($request, 'index'), status => 303);
}

compose(
    routes => [
        route('/' => \&index, name => 'index'),
        route('/tasks' => \&create, methods => ['POST'], name => 'create'),
        route('/tasks/{id}/toggle' => \&toggle, methods => ['POST'], name => 'toggle'),
        route('/tasks/{id}/delete' => \&remove, methods => ['POST'], name => 'delete'),
        mount('/static', app => PAGI::App::File->from_app_path('public'), name => 'static'),
    ],
    middleware => [
        middleware('Session'),
        # The token lives in the session. Every unsafe request is checked
        # here: a cross-site one is refused, and a form's csrf_token field is
        # read from its body -- which the route then reads as usual -- and a
        # missing or wrong one is refused with a 403.
        middleware('CSRF', session => 1, form_field => 'csrf_token'),
        # The board's errors, answered in one place. A route's error is
        # answered at that route, with its own Request: the form create
        # read, and the id in the path.
        middleware('ErrorHandler', catch => {
            'TaskBoard::TitleTaken' => async sub ($request, $error) {
                my ($values) = validate(await $request->form_params);
                return page($request, 'index.tt', tasks => tasks($request)->{list},
                    form => $values, status => 409,
                    errors => { title => 'There is already a task called "'
                        . $error->exception->title . '".' });
            },
            'TaskBoard::NoSuchTask' => sub ($request, $error) {
                return response('Text', 'No such task: ' . $request->path_param('id') . '.',
                    status => 404);
            },
            # A page that does not exist: the router's 404, answered here.
            404 => sub ($request, $error) {
                return response('Text', 'No such page: ' . $request->path . '.', status => 404);
            },
        }),
    ],
    lifespan => {
        startup => sub ($state, $scope) { $state->{board} = { next => 1, list => [] } },
    },
);
