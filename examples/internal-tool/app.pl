#!/usr/bin/env perl
#
# An internal tool: a task board for a small team. The everyday HTML
# workflow every web framework is judged on: pages from templates, a form
# that re-renders with its errors, redirect after POST, a flash message on
# the next page, CSRF on every form, a stylesheet from a static directory.
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
use File::Basename qw(dirname);
use Future::AsyncAwait;
use Template;
use PAGI::App::File;
use PAGI::CSRF qw(csrf csrf_protect);
use PAGI::Session qw(session);
use PAGI::Tools qw(app_state compose middleware mount path_for response route);

my $tt = Template->new(INCLUDE_PATH => dirname(__FILE__) . '/templates', ENCODING => 'utf8');

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

async sub index ($request) {
    return page($request, 'index.tt', tasks => tasks($request)->{list}, form => {}, errors => {});
}

async sub create ($request) {
    my $form = await $request->form_params;
    my ($values, $errors) = validate($form);
    return page($request, 'index.tt', tasks => tasks($request)->{list},
        form => $values, errors => $errors, status => 422)
        if %$errors;

    my $board = tasks($request);
    push @{ $board->{list} }, { id => $board->{next}++, %$values, done => 0 };
    flash($request, "Added \"$values->{title}\".");
    return response('Redirect', path_for($request, 'index'), status => 303);
}

async sub toggle ($request) {
    my $id = $request->path_param('id');
    my ($task) = grep { $_->{id} == $id } @{ tasks($request)->{list} };
    return response('Text', 'No such task', status => 404) unless $task;
    $task->{done} = !$task->{done} || 0;
    flash($request, $task->{done} ? "Done: $task->{title}." : "Reopened: $task->{title}.");
    return response('Redirect', path_for($request, 'index'), status => 303);
}

async sub remove ($request) {
    my $id    = $request->path_param('id');
    my $board = tasks($request);
    my $before = @{ $board->{list} };
    @{ $board->{list} } = grep { $_->{id} != $id } @{ $board->{list} };
    return response('Text', 'No such task', status => 404) if @{ $board->{list} } == $before;
    flash($request, 'Deleted.');
    return response('Redirect', path_for($request, 'index'), status => 303);
}

compose(
    routes => [
        route('/' => \&index, name => 'index'),
        # Each form route checks the form's csrf_token field before its
        # handler runs: a missing or wrong token is refused with a 403.
        route('/tasks' => csrf_protect(\&create), methods => ['POST'], name => 'create'),
        route('/tasks/{id}/toggle' => csrf_protect(\&toggle), methods => ['POST'], name => 'toggle'),
        route('/tasks/{id}/delete' => csrf_protect(\&remove), methods => ['POST'], name => 'delete'),
        mount('/static', app => PAGI::App::File->from_app_path('public'), name => 'static'),
    ],
    middleware => [
        middleware('Session'),
        # The token lives in the session; a cross-site POST is refused here,
        # and a form's token is left to csrf_protect on its route.
        middleware('CSRF', session => 1, form_field => 'csrf_token'),
    ],
    lifespan => {
        startup => sub ($state, $scope) { $state->{board} = { next => 1, list => [] } },
    },
);
