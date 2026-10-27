use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::CSRF qw(csrf);
use PAGI::Tools qw(compose middleware response route);

# With form_field set, the middleware checks a multipart form's token
# itself, reading the body only as far as the token part and deciding in
# byte order: the answer does not depend on how the client's bytes were split
# into events, and no limit is applied to a part after the token -- the
# route's own parse applies its limits to the whole body. Whoever runs next
# is handed a receive that delivers the whole body again.

my $token = 'ab' x 32;
our $boundary = 'XyZ';

sub part {
    my ($name, $value, $filename) = @_;
    my $disposition = qq{form-data; name="$name"} . (defined $filename ? qq{; filename="$filename"} : '');
    return "--$boundary\r\nContent-Disposition: $disposition\r\n"
        . (defined $filename ? "Content-Type: text/plain\r\n" : '') . "\r\n$value\r\n";
}
sub body_of { return join('', @_) . "--$boundary--\r\n" }

my $big = 'n' x 4096;
my $token_first = body_of(part(csrf_token => $token), part(notes => $big), part(file => 'hello', 'a.txt'));
my $big_first   = body_of(part(notes => $big), part(csrf_token => $token), part(file => 'hello', 'a.txt'));

# The body as events: one, one byte each, or split at the given offsets.
sub layouts {
    my ($body) = @_;
    my $at = sub { my @cuts = @_; my ($from, @events) = (0); for my $cut (@cuts, length $body) { push @events, substr($body, $from, $cut - $from); $from = $cut } [ @events ] };
    my $second = index($body, "--$boundary", 1);
    my $in_token = index($body, $token) + 10;
    return (
        'one event'                  => [$body],
        'one-byte events'            => [ split //, $body ],
        'split in the boundary line' => $at->($second + 3),
        'split in the token'         => $in_token > 10 ? $at->($in_token) : $at->(5),
        'split between parts'        => $at->($second),
    );
}

# Runs $app on a POST with $events as the body; returns status, body, and
# how many times the app's receive was called.
sub run {
    my ($app, $events, %headers) = @_;
    # last_more: the last event says more is coming; the receive then reports
    # the disconnect, as some servers end a body.
    my @incoming = map { { type => 'http.request', body => $events->[$_],
        more => ($_ < $#$events || $headers{last_more} ? 1 : 0) } } 0 .. $#$events;
    my ($calls, @sent) = (0);
    my $scope = { type => 'http', method => 'POST', path => '/', raw_path => '/', query_string => '', scheme => 'http',
        headers => [['content-type', $headers{content_type} // "multipart/form-data; boundary=$boundary"],
                    ['cookie', "csrf_token=$token"]] };
    my $receive = sub { $calls++; Future->done(@incoming ? shift @incoming : { type => 'http.disconnect' }) };
    $app->($scope, $receive, sub { push @sent, $_[0]; Future->done })->get;
    my ($start) = grep { $_->{type} eq 'http.response.start' } @sent;
    return ($start->{status}, join('', map { $_->{body} // '' } grep { $_->{type} eq 'http.response.body' } @sent), $calls);
}

# The route reports what its own parse saw.
async sub report {
    my ($request) = @_;
    my $form = await $request->form_params;
    my $uploads = await $request->uploads;
    return response('Text', sprintf 'notes=%d file=%s failure=%s', length($form->get('notes') // ''),
        ($uploads->get('file') ? 'yes' : 'no'), csrf($request)->failure // 'none');
}
sub app_with {
    my (%csrf) = @_;
    return compose(routes => [route('/' => \&report, methods => ['POST'])],
        middleware => [middleware('CSRF', form_field => 'csrf_token', %csrf)])->to_app;
}

subtest 'the token first: the same answer in every layout, and the route parses it all' => sub {
    my $app = app_with(max_form_size => 1024);
    my %layouts = layouts($token_first);
    for my $name (sort keys %layouts) {
        my ($status, $body) = run($app, $layouts{$name});
        is [$status, $body], [200, 'notes=4096 file=yes failure=none'], "$name: passes; the 4 KiB field after the token is not the middleware's to limit";
    }
};

subtest 'a 4 KiB field before the token: over the budget in every layout' => sub {
    my $app = app_with(max_form_size => 1024);
    my %layouts = layouts($big_first);
    for my $name (sort keys %layouts) {
        my ($status, $body) = run($app, $layouts{$name});
        is [$status, $body], [413, 'Request body too large'], "$name: 413";
    }
};

subtest 'a wrong token, no token, or a file first is refused' => sub {
    my $app = app_with();
    is [run($app, [body_of(part(csrf_token => 'forged'), part(file => 'x', 'a.txt'))])]->[0], 403, 'wrong';
    is [run($app, [body_of(part(title => 'hi'))])]->[0], 403, 'no token part';
    is [run($app, [body_of(part(file => 'x', 'a.txt'), part(csrf_token => $token))])]->[0], 403, 'a file before the token';
    is [run($app, [body_of(part(csrf_token => $token, 'token.txt'))])]->[0], 403, 'a csrf_token part that is a file';
};

subtest 'the first token part decides' => sub {
    my $app = app_with();
    is [run($app, [body_of(part(csrf_token => $token), part(csrf_token => 'forged'))])]->[0], 200;
    is [run($app, [body_of(part(csrf_token => 'forged'), part(csrf_token => $token))])]->[0], 403;
};

subtest 'a quoted boundary in a mixed-case Content-Type' => sub {
    my $quoted = 'Xy.Z_1';    # the route's parser refuses a space, which RFC 2046 allows
    local $boundary = $quoted;
    my $body = body_of(part(csrf_token => $token), part(title => 'hi'));
    my ($status) = run(app_with(), [$body], content_type => qq{Multipart/Form-Data; boundary="$quoted"});
    is $status, 200;
};

subtest 'many small fields before the token run past the budget' => sub {
    my $body = body_of((map { part("f$_" => 'v' x 20) } 1 .. 40), part(csrf_token => $token));
    is [run(app_with(max_form_size => 1024), [$body])]->[0], 413;
};

subtest 'a malformed body is the 400; no boundary is the 400 without reading' => sub {
    my ($status, $body) = run(app_with(), ["--$boundary\r\nno header separator here"]);
    is [$status, $body], [400, 'The multipart request body could not be parsed.'], 'a part that never ends';
    my $calls;
    ($status, $body, $calls) = run(app_with(), [body_of(part(csrf_token => $token))], content_type => 'multipart/form-data');
    is [$status, $body, $calls], [400, 'The multipart request body could not be parsed.', 0], 'no boundary: nothing read';
};

subtest 'under refuse => 0 every outcome reaches the route, with the whole body' => sub {
    my $raw = compose(routes => [route('/' => async sub {
        my ($request) = @_;
        return response('Text', 'bytes=' . length(await $request->body) . ' failure=' . (csrf($request)->failure // 'none'));
    }, methods => ['POST'])], middleware => [middleware('CSRF', form_field => 'csrf_token', refuse => 0, max_form_size => 1024)])->to_app;
    for my $case (
        ['matching',     $token_first,                                             'none'],
        ['wrong',        body_of(part(csrf_token => 'forged')),                    'mismatch'],
        ['file first',   body_of(part(file => 'x', 'a.txt'), part(csrf_token => $token)), 'missing_token'],
        ['over budget',  $big_first,                                               'missing_token'],
        ['malformed',    "--$boundary\r\nno header separator here",                'missing_token'],
    ) {
        my ($name, $body, $failure) = @$case;
        my (undef, $text) = run($raw, [$body]);
        is $text, 'bytes=' . length($body) . " failure=$failure", "$name: the whole body, $failure recorded";
    }
};

subtest 'a refuse handler is given the whole multipart form' => sub {
    my $app = app_with(refuse => async sub {
        my ($request) = @_;
        my $form = await $request->form_params;
        return response('Text', 'refused title=' . $form->get('title') . ' failure=' . csrf($request)->failure, status => 403);
    });
    my ($status, $body) = run($app, [body_of(part(csrf_token => 'forged'), part(title => 'tea'))]);
    is [$status, $body], [403, 'refused title=tea failure=mismatch'];
};

subtest 'a boundary the parser cannot take is the 400, read nothing; under refuse => 0 the route runs' => sub {
    for my $odd ('x y', 'a@b') {
        local $boundary = $odd;
        my $body = body_of(part(csrf_token => $token));
        my ($status, $text, $calls) = run(app_with(), [$body], content_type => qq{multipart/form-data; boundary="$odd"});
        is [$status, $text, $calls], [400, 'The multipart request body could not be parsed.', 0], qq{boundary "$odd"};
        my $raw = compose(routes => [route('/' => sub { response('Text', 'ran failure=' . (csrf($_[0])->failure // 'none')) }, methods => ['POST'])],
            middleware => [middleware('CSRF', form_field => 'csrf_token', refuse => 0)])->to_app;
        ($status, $text) = run($raw, [$body], content_type => qq{multipart/form-data; boundary="$odd"});
        is [$status, $text], [200, 'ran failure=missing_token'], qq{boundary "$odd", refuse => 0: the route decides};
    }
};

subtest 'a body that ends with a disconnect after its closing boundary is a complete body' => sub {
    my ($status) = run(app_with(), [body_of(part(title => 'hi'))], last_more => 1);
    is $status, 403, 'no token part: refused, not an error';
    ($status) = run(app_with(), [body_of(part(csrf_token => $token), part(title => 'hi'))], last_more => 1);
    is $status, 200, 'the token part: passes';
    like dies { run(app_with(), ["--$boundary\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhal"], last_more => 1) },
        qr/Request body incomplete: client disconnected mid-body/, 'cut off before the token: the client left, as the route would see it';
};

done_testing;
