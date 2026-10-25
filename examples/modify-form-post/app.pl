#!/usr/bin/env perl
#
# A middleware that rewrites a form POST's body before the application sees
# it: the username field is trimmed and upper-cased, and a
# middleware_processed field is added. The route reads the form as usual and
# sees only the rewritten one. The same application in Starlette is app.py.
#
# The middleware reads the whole body itself, so it owns the client's
# receive from then on: it hands the application a receive that delivers the
# rewritten body once and then carries on with the client's receive, which
# reports the disconnect when the client goes.
#
# Run:  pagi-server --app examples/modify-form-post/app.pl --port 5000
# Try:  curl localhost:5000/submit --data-urlencode 'username= john_doe ' -d role=Developer

use v5.40;
use Future::AsyncAwait;
use List::Util qw(pairmap);
use PAGI::Request;
use PAGI::Tools qw(compose middleware response route);

# name => value pairs as an application/x-www-form-urlencoded body.
sub form_encode (@pairs) {
    my $escape = sub ($text) {
        utf8::encode($text);
        $text =~ s/([^A-Za-z0-9\-._~ ])/sprintf('%%%02X', ord $1)/ge;
        return $text =~ tr/ /+/r;
    };
    return join '&', pairmap { $escape->($a) . '=' . $escape->($b) } @pairs;
}

sub modify_form_post ($app) {
    return async sub ($scope, $receive, $send) {
        return await $app->($scope, $receive, $send)
            unless $scope->{type} eq 'http' && $scope->{method} eq 'POST'
                && (PAGI::Request->new($scope, $receive)->content_type // '') eq 'application/x-www-form-urlencoded';

        # Read the whole form from the client.
        my $form = await PAGI::Request->new($scope, $receive)->form_params;

        # Rewrite it: clean up the username, mark it processed.
        my @fields = pairmap { $a eq 'username' ? ($a, uc($b =~ s/\A\s+|\s+\z//gr)) : ($a, $b) } $form->flatten;
        push @fields, middleware_processed => 'true';
        my $body = form_encode(@fields);

        # The application gets a scope whose Content-Length is the new
        # body's, and a receive that delivers that body once.
        my $rewritten_scope = { %$scope, headers => [
            (grep { lc($_->[0]) ne 'content-length' } @{ $scope->{headers} }),
            ['content-length', length $body],
        ] };
        my $delivered = 0;
        my $rewritten_receive = async sub {
            return await $receive->() if $delivered++;
            return { type => 'http.request', body => $body, more => 0 };
        };
        await $app->($rewritten_scope, $rewritten_receive, $send);
    };
}

sub html_escape ($text) {
    my %entity = ('&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&#39;');
    return $text =~ s/([&<>"'])/$entity{$1}/gr;
}

sub show_form ($request) {
    return response('HTML', <<~'HTML');
        <form action="/submit" method="post">
            <label>Username: <input type="text" name="username" value=" john_doe "></label><br><br>
            <label>Role: <input type="text" name="role" value="Developer"></label><br><br>
            <button type="submit">Submit Form</button>
        </form>
        HTML
}

# The route reads the form as usual: it sees the rewritten one.
async sub handle_submit ($request) {
    my $form = await $request->form_params;
    my $received = join ', ', map { "'$_->[0]': '" . ($_->[1] // '') . "'" }
        [received_username      => $form->get('username')],
        [received_role          => $form->get('role')],
        [injected_by_middleware => $form->get('middleware_processed')];
    return response('HTML', '<h3>Endpoint Received:</h3><pre>' . html_escape("{$received}") . '</pre>');
}

compose(
    routes => [
        route('/' => \&show_form, methods => ['GET']),
        route('/submit' => \&handle_submit, methods => ['POST']),
    ],
    middleware => [middleware(\&modify_form_post)],
);
