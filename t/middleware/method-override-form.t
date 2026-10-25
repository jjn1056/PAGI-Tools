use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Middleware::MethodOverride;
use PAGI::Test::Client;
use PAGI::Tools qw(compose middleware response route);

# MethodOverride takes the method from the header or the _method query
# parameter, which an HTML form puts in its action URL. It never reads the
# body: that is the application's, and reaches it untouched.

# An application that reads the body from $receive itself and answers with
# the method it was given and the body it read.
async sub echo {
    my ($scope, $receive, $send) = @_;
    my $body = '';
    while (1) {
        my $event = await $receive->();
        last unless $event->{type} eq 'http.request';
        $body .= $event->{body} // '';
        last unless $event->{more};
    }
    await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
    await $send->({ type => 'http.response.body', body => "$scope->{method} $body", more => 0 });
}

sub native {
    return PAGI::Test::Client->new(app => PAGI::Middleware::MethodOverride->new(@_)->wrap(\&echo));
}

my %urlencoded = ('Content-Type' => 'application/x-www-form-urlencoded');
my $boundary = 'XyZ';
my %multipart = ('Content-Type' => "multipart/form-data; boundary=$boundary");
sub multipart_body {
    my (%field) = @_;
    return join "\r\n",
        (map { ("--$boundary", qq{Content-Disposition: form-data; name="$_"}, '', $field{$_}) } sort keys %field),
        "--$boundary--", '';
}

subtest 'a form field is not an override; the body reaches the application untouched' => sub {
    my $client = native();
    is $client->post('/', body => '_method=DELETE&title=hi', headers => \%urlencoded)->text,
        'POST _method=DELETE&title=hi', 'urlencoded';
    my $body = multipart_body(_method => 'PATCH', title => 'hi');
    is $client->post('/', body => $body, headers => \%multipart)->text, "POST $body", 'multipart';
};

subtest 'a form puts the method in its action URL' => sub {
    my $client = native();
    is $client->post('/?_method=DELETE', body => 'title=hi', headers => \%urlencoded)->text,
        'DELETE title=hi', 'the query overrides, and the body reaches the application';
    is $client->post('/?_method=delete', body => 'title=hi', headers => \%urlencoded)->text,
        'DELETE title=hi', 'the value is case-insensitive';
};

subtest 'the header, then the query' => sub {
    my $client = native();
    is $client->post('/?_method=DELETE', body => 'title=hi', headers => { %urlencoded, 'X-HTTP-Method-Override' => 'PUT' })->text,
        'PUT title=hi', 'the header beats the query';
};

subtest 'what is left alone' => sub {
    my $client = native();
    is $client->put('/?_method=DELETE', body => 'title=hi', headers => \%urlencoded)->text, 'PUT title=hi',
        'only a POST is overridden';
    is $client->post('/?_method=GET', body => 'title=hi', headers => \%urlencoded)->text, 'POST title=hi',
        'a method outside allowed_methods is ignored';
};

subtest 'check_param => 0 ignores the query; check_header => 0 the header' => sub {
    is native(check_param => 0)->post('/?_method=PUT', body => 'title=hi', headers => \%urlencoded)->text,
        'POST title=hi', 'check_param => 0';
    is native(check_header => 0)->post('/', body => 'title=hi', headers => { %urlencoded, 'X-HTTP-Method-Override' => 'PUT' })->text,
        'POST title=hi', 'check_header => 0';
};

subtest 'the removed body options die naming what replaces them' => sub {
    like dies { PAGI::Middleware::MethodOverride->new(check_form => 0) },
        qr/MethodOverride 'check_form' was removed: it never reads the body; put the method in the form's action URL \(\?_method=DELETE\)/,
        'check_form';
    like dies { PAGI::Middleware::MethodOverride->new(body_buffer => sub {}) },
        qr/MethodOverride 'body_buffer' was removed: it never reads the body/, 'body_buffer';
};

# A Compose route reporting the method and what PAGI::Request gives it.
my %reader = (
    form   => async sub { (await $_[0]->form_params)->get('title') // '' },
    stream => async sub { $_[0]->body_stream; 'streams' },
);
async sub report {
    my ($request) = @_;
    my @parts = ($request->method);
    for my $name (split /,/, $request->query_param('read') // '') {
        my $got = await $reader{$name}->($request)
            ->else(sub { my ($error) = @_; Future->done('dies: ' . ($error =~ s/ at \S+ line \d+.*//sr)) });
        push @parts, "$name=$got";
    }
    return response('Text', join ' | ', @parts);
}

sub composed {
    my (@middleware) = @_;
    return PAGI::Test::Client->new(app => compose(
        routes     => [route('/' => \&report, methods => [qw(POST PUT PATCH DELETE)])],
        middleware => \@middleware,
    ));
}

subtest 'an application below it may stream an overridden form' => sub {
    is composed(middleware('MethodOverride'))
        ->post('/?_method=DELETE&read=stream', body => 'title=hi', headers => \%urlencoded)->text,
        'DELETE | stream=streams', 'body_stream works: nothing above it read the body';
};

subtest 'with CSRF, in either order, the method in the URL and the token in the form' => sub {
    for my $order (['CSRF', 'MethodOverride'], ['MethodOverride', 'CSRF']) {
        my $client = composed(map { middleware($_) } @$order);
        $client->put('/');    # any response sets the CSRF cookie
        my $token = $client->cookie('csrf_token');
        my $res = $client->post('/?_method=DELETE&read=form', body => "csrf_token=$token&title=hi",
            headers => \%urlencoded);
        is [$res->status, $res->text], [200, 'DELETE | form=hi'], join(' outside ', @$order);
        is $client->post('/?_method=DELETE', body => 'csrf_token=forged', headers => \%urlencoded)->status, 403,
            join(' outside ', @$order) . ': a wrong token is still refused';
    }
};

done_testing;
