use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::CSRF qw(csrf);
use PAGI::Test::Client;
use PAGI::Tools qw(compose middleware response route);

# With form_field set, the middleware checks a urlencoded form's token
# itself: it reads the body ahead -- at most max_form_size bytes -- through a
# recording receive, and hands whoever runs next a receive that delivers the
# whole body again. Every form route is protected; the route reads its form
# as usual. (No header and no Origin: a plain form post from a client that
# sends neither, the case a route without csrf_protect used to accept.)

my $ran = 0;

# The route reports the title, how many csrf_token fields it read, and the
# recorded failure.
async sub report {
    my ($request) = @_;
    $ran++;
    my $form = await $request->form_params;
    my @tokens = $form->get_all('csrf_token');
    return response('Text', sprintf 'title=%s tokens=%d failure=%s',
        $form->get('title') // '', scalar(@tokens), csrf($request)->failure // 'none');
}

sub client_with {
    my (%csrf) = @_;
    my $client = PAGI::Test::Client->new(app => compose(
        routes     => [route('/' => \&report, methods => [qw(GET POST PUT)])],
        middleware => [middleware('CSRF', form_field => 'csrf_token', %csrf)],
    ));
    $client->get('/');    # gets its CSRF cookie
    return ($client, $client->cookie('csrf_token'));
}

my %urlencoded = ('Content-Type' => 'application/x-www-form-urlencoded');
sub post_raw { my ($client, $body, %headers) = @_; return $client->post('/', body => $body, headers => { %urlencoded, %headers }) }

subtest 'a matching field passes, and the route reads the whole form' => sub {
    my ($client, $token) = client_with();
    my $res = $client->post('/', form => { title => 'tea', csrf_token => $token });
    is [$res->status, $res->text], [200, 'title=tea tokens=1 failure=none'];
    is $client->put('/', form => { title => 'cups', csrf_token => $token })->text,
        'title=cups tokens=1 failure=none', 'every unsafe method';
};

subtest 'a wrong or missing field is refused before the route' => sub {
    my ($client, $token) = client_with();
    my $before = $ran;
    is $client->post('/', form => { title => 'tea', csrf_token => 'forged' })->status, 403, 'wrong';
    is $client->post('/', form => { title => 'tea' })->status, 403, 'missing';
    is $client->post('/', form => { title => 'tea', csrf_token => '' })->status, 403, 'empty';
    is $ran, $before, 'the route never ran';
};

subtest 'the budget: max_form_size bytes pass, one more is a 413' => sub {
    my ($client, $token) = client_with(max_form_size => 128);
    my $head = "csrf_token=$token&title=";
    my $at   = $head . ('x' x (128 - length $head));
    my $res = post_raw($client, $at);
    is [$res->status, length $at], [200, 128], 'exactly the budget passes';
    $res = post_raw($client, "${at}y");
    is [$res->status, $res->text], [413, 'Request body too large'], 'one byte more is answered here';
};

subtest 'the first token in the body decides' => sub {
    my ($client, $token) = client_with();
    is post_raw($client, "csrf_token=$token&csrf_token=forged&title=a")->text, 'title=a tokens=2 failure=none';
    is post_raw($client, "csrf_token=forged&csrf_token=$token&title=a")->status, 403;
};

subtest 'a urlencoded Content-Type with parameters is a form' => sub {
    my ($client, $token) = client_with();
    my $res = post_raw($client, "csrf_token=$token&title=a", 'Content-Type' => 'application/x-www-form-urlencoded; charset=utf-8');
    is $res->status, 200;
};

subtest 'an empty form is missing its token' => sub {
    my ($client) = client_with();
    is post_raw($client, '')->status, 403;
    ($client) = client_with(refuse => 0);
    is post_raw($client, '')->text, 'title= tokens=0 failure=missing_token', 'under refuse => 0 the route reads an empty form';
};

subtest 'a refuse handler is given the whole form' => sub {
    my ($client) = client_with(refuse => async sub {
        my ($request) = @_;
        my $form = await $request->form_params;
        return response('Text', 'refused title=' . $form->get('title') . ' failure=' . csrf($request)->failure, status => 403);
    });
    my $res = $client->post('/', form => { title => 'tea', csrf_token => 'forged' });
    is [$res->status, $res->text], [403, 'refused title=tea failure=mismatch'];
};

subtest 'under refuse => 0 every outcome reaches the route, with the whole body' => sub {
    my ($client, $token) = client_with(refuse => 0, max_form_size => 128);
    is $client->post('/', form => { title => 'tea', csrf_token => 'forged' })->text, 'title=tea tokens=1 failure=mismatch';
    is $client->post('/', form => { title => 'tea' })->text, 'title=tea tokens=0 failure=missing_token';
    my $long = 'x' x 300;
    is post_raw($client, "title=$long&csrf_token=$token")->text, "title=$long tokens=1 failure=missing_token",
        'over the budget: not read further, the route reads it all';
};

subtest 'max_form_size must be a positive integer' => sub {
    require PAGI::Middleware::CSRF;
    for my $bad (0, -1, 'x', 1.5, []) {
        like dies { PAGI::Middleware::CSRF->new(max_form_size => $bad) }, qr/CSRF max_form_size must be a positive integer/,
            'max_form_size ' . (ref $bad ? 'arrayref' : $bad);
    }
};

done_testing;
