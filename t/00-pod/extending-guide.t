#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';

# PAGI::Tools::Extending links to the rules instead of restating them, so its
# links must land on real sections, and its one worked example must do what
# the guide says it does.

my $guide_file = 'lib/PAGI/Tools/Extending.pod';
my $guide = do { open my $fh, '<', $guide_file or die "$guide_file: $!"; local $/; <$fh> };

# The verbatim blocks, in order: runs of indented lines (blank lines inside a
# run kept), with the four-space indent removed.
sub verbatim_blocks {
    my ($pod) = @_;
    my (@blocks, @run, $blank);
    for my $line (split /\n/, $pod) {
        if ($line =~ /^    /) {
            push @run, ('') x $blank if @run && $blank;
            push @run, substr($line, 4);
            $blank = 0;
        }
        elsif ($line eq '') {
            $blank++ if @run;
        }
        else {
            push @blocks, join("\n", @run) . "\n" if @run;
            @run = ();
            $blank = 0;
        }
    }
    push @blocks, join("\n", @run) . "\n" if @run;
    return @blocks;
}

# Modules outside this distribution the guide may link to; any other target
# must be a file under lib/.
my %external = map { $_ => 1 } qw(PAGI::Building PAGI::Spec::Www Future::IO);

subtest 'every link to this distribution names a section it has' => sub {
    my @links = $guide =~ /L<([^<>|]+)>/g;
    ok(@links > 20, 'the guide links to the rules (' . scalar(@links) . ' links)');
    for my $link (@links) {
        my ($module, $section) = split m{/}, $link, 2;
        if ($external{$module}) {
            pass("$link: outside this distribution");
            next;
        }
        (my $path = $module) =~ s{::}{/}g;
        my ($file) = grep { -f } map { "lib/$path.$_" } qw(pm pod);
        ok($file, "$link: $module is in lib/") or next;
        next unless defined $section;
        $section =~ s/\A"(.*)"\z/$1/;
        my $source = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };
        like($source, qr/^=head\d \Q$section\E$/m, "$link: the section exists");
    }
};

my @blocks = verbatim_blocks($guide);
is(scalar @blocks, 2, 'two code blocks: the constructor call and the wrapping example');

subtest 'the constructor call builds what it says' => sub {
    my ($name, $content, $code, $headers, $type) = ('Text', 'hi', 201, [[ 'X-A' => 'b' ]], 'text/csv');
    my $value = eval "use PAGI::Response qw(response); $blocks[0]" or diag $@;
    isa_ok($value, ['PAGI::Response::Text'], 'the class named');
    is($value && $value->status, 201, 'the status');
    is($value && $value->header('X-A'), 'b', 'the headers');
    like($value && $value->content_type, qr{^text/csv}, 'the content type');
};

subtest 'the example frameworks it names exist, and need what it says' => sub {
    my @paths = $guide =~ /F<(examples\/[^>]+)>/g;
    ok(@paths >= 2, 'it names the examples');
    for my $path (@paths) {
        ok(-d $path, "$path exists");
        my @modules = glob "$path/lib/*.pm";
        ok(@modules && !grep({ !do { open my $fh, '<', $_ or die; local $/; <$fh> =~ /^use v5\.40;/m } } @modules),
            "$path needs Perl 5.40, as the guide says");
    }
};

subtest 'the rules it states are the code\'s' => sub {
    use PAGI::Response qw(response status_forbids_body);
    use PAGI::Routing qw(route request_response);

    # Bodyless statuses: the set status_forbids_body names, and which
    # classes take an empty body on them.
    my @bodyless = grep { status_forbids_body($_) } 100 .. 599;
    is([ grep { $_ >= 200 } @bodyless ], [204, 205, 304], 'status_forbids_body: 1xx, 204, 205, 304');
    like($guide, qr/On 1xx, 204, 205 and 304/, 'the guide names the same statuses');
    for my $name ('+PAGI::Response', 'Text', 'HTML') {
        ok(lives { response($name, '', status => $_) for 204, 205 }, "$name takes an empty body on 204 and 205");
    }
    ok(dies { response('JSON', undef, status => 204) }, 'JSON does not');
    ok(dies { response('Problem', { title => 't' }, status => 204) }, 'nor Problem');
    ok(dies { response('Redirect', '/x', status => 304) }, 'nor Redirect');
    like($guide, qr/the base class, Text and HTML\s+take an empty body/, 'the guide names the classes that do');
    like($guide, qr/JSON, Problem and Redirect\s+never take/, 'and the ones that do not');

    # request_factory belongs to request_response, not to route.
    like(dies { route('/x' => sub { }, request_factory => sub { }) }, qr/unknown route option 'request_factory'/,
        'route takes no request_factory');
    ok(lives { request_response(sub { }, request_factory => sub { }) }, 'request_response does');
    unlike($guide, qr/a route's\s+C<request_factory>/, "the guide does not call it a route's");
    like($guide, qr/L<PAGI::Routing\/request_response>'s\s+C<request_factory>/, "it names request_response's");

    # Only Request lists the methods other methods call; its own fields are
    # scope and receive.
    my %source = map { $_ => do { open my $fh, '<', "lib/PAGI/$_.pm" or die; local $/; <$fh> } } qw(Request WebSocket SSE);
    like($source{Request}, qr/Also read by/, 'Request lists the methods other methods call');
    unlike($source{$_}, qr/Also read by/, "$_ does not") for qw(WebSocket SSE);
    like($guide, qr/Request's\s+C<scope> and C<receive>/, "the guide gives Request's own fields");
    like($guide, qr/Request also lists the methods/, 'and says only Request lists methods');

    # The sections it cites for representations and memory say so.
    my $metadata = do { open my $fh, '<', 'lib/PAGI/Response.pm' or die; local $/; <$fh> };
    my ($section) = $metadata =~ /^=head2 metadata\n(.*?)^=head/ms;
    like($section, qr/is_buffered/, 'Response metadata documents is_buffered');
    like($guide, qr/C<is_buffered>[^.]*L<PAGI::Response\/metadata>/s, 'the guide cites it there');
    like($guide, qr/L<PAGI::Response\/CLASS MODEL>/, 'and cites CLASS MODEL for representations');
};

subtest 'the wrapping example works as the guide says' => sub {
    my $example = $blocks[1];
    like($example, qr/^package My::Framework::Response;/, 'the block is the example');
    ok(eval "$example; 1", 'it compiles and loads') or diag($@), return;

    my $res = My::Framework::Response->new;
    isa_ok($res->status(201), ['My::Framework::Response'], 'a delegated setter returns the framework response');
    isa_ok($res->header('X-Staged' => 'yes'), ['My::Framework::Response'], 'and so does header');
    isa_ok($res->cookie(sid => '1'), ['My::Framework::Response'], 'and cookie');
    isa_ok($res->content_type('text/csv'), ['My::Framework::Response'], 'and content_type');
    is($res->status, 201, 'a getter still returns its value');

    my $value = $res->finalize('Text', 'hello');
    isa_ok($value, ['PAGI::Response::Text'], 'finalize builds the chosen class');
    is($value->status, 201, 'with the staged status');
    is($value->header('X-Staged'), 'yes', 'and the staged headers');
    like($value->header('Set-Cookie'), qr/^sid=1/, 'and cookies');
    like($value->content_type, qr{^text/csv}, 'and the staged content type');

    my $plain = My::Framework::Response->new->finalize(undef, 'bytes');
    isa_ok($plain, ['PAGI::Response'], 'no class is the base class');
    is($plain->status, 200, 'nothing staged: 200');

    my $line = __LINE__ + 1;
    my $error = dies { My::Framework::Response->new->finalize('Text', undef) };
    like($error, qr/^Text response body must be a defined Unicode scalar at \Q${\__FILE__}\E line $line\.$/,
        "a refusal names the framework user's line, not the framework's");
};

done_testing;
