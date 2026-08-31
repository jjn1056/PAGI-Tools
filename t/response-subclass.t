use strict;
use warnings;
use File::Temp qw(tempfile);
use Future;
use Test2::V0;
use PAGI::Response;
use PAGI::Response::File;
use PAGI::Response::Stream;
use PAGI::Utils qw(invoke_app);

{
    package T::IdentityResponse;
    use parent -norequire, 'PAGI::Response';
    sub default_content_type { 'application/x-identity' }
    sub render { $_[1] }
}

{ package T::FileResponse; use parent -norequire, 'PAGI::Response::File'; }
{ package T::StreamResponse; use parent -norequire, 'PAGI::Response::Stream'; }

sub http_scope {
    return { type => 'http', method => 'GET', path => '/', headers => [] };
}

sub receive {
    return sub {
        Future->done({ type => 'http.request', body => '', more => 0 });
    };
}

sub invoke_value {
    my ($value, $through) = @_;
    my @events;
    my $send = sub { push @events, $_[0]; Future->done };
    if ($through eq 'to_app') {
        my $app = $value->to_app;
        $app->(http_scope(), receive(), $send)->get;
    }
    else {
        invoke_app($value, http_scope(), receive(), $send)->get;
    }
    return \@events;
}

my $res = T::IdentityResponse->new('bytes');
isa_ok $res, ['PAGI::Response'], 'subclass inherits the base value contract';
is $res->content_type, 'application/x-identity', 'subclass default applies';
is $res->body, 'bytes', 'subclass render supplies the body';

my ($fh, $path) = tempfile();
print {$fh} 'selected file' or die "cannot write selected file: $!";
close $fh or die "cannot close selected file: $!";

my @values = (
    [base => T::IdentityResponse->new('base subclass')],
    [file => T::FileResponse->new($path)],
    [stream => T::StreamResponse->new(sub { $_[0]->write('stream subclass') })],
);

for my $class (qw(
    PAGI::Response PAGI::Response::File PAGI::Response::Stream
    T::IdentityResponse T::FileResponse T::StreamResponse
)) {
    ok(!$class->can('respond'), "$class exposes no public respond method");
}

for my $case (@values) {
    my ($kind, $value) = @$case;
    for my $through (qw(to_app invoke_app)) {
        my $events = invoke_value($value, $through);
        is($events->[0]{type}, 'http.response.start',
            "$kind subclass starts through $through");
        if ($kind eq 'file') {
            is($events->[1]{file}, $path,
                "File subclass preserves selected delivery through $through");
        }
        else {
            my $body = join '', map { $_->{body} // '' }
                grep { ($_->{type} // '') eq 'http.response.body' } @$events;
            my $expected = $kind eq 'base' ? 'base subclass' : 'stream subclass';
            is($body, $expected, "$kind subclass body works through $through");
        }
    }
}

done_testing;
