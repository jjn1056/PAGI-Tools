use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempdir);
use lib 'lib';

use PAGI::Endpoint::HTTP ();
use PAGI::Middleware ();
use PAGI::Middleware::Builder;
use PAGI::Middleware::RequestClass;
use PAGI::Middleware::Session qw(session_store);
use PAGI::Request ();
use PAGI::Response qw(response);
use PAGI::Response::Text ();
use PAGI::Routing qw(endpoint middleware);

# Every place PAGI-Tools takes a class by name loads it the same way: a class
# already defined (here, in this file) is used as it is; otherwise its file is
# required, and a class with no file, or a file that fails to load, dies
# naming the call. A file that failed once is never used half-compiled.

{
    package Local::Inline::Endpoint;
    use parent -norequire, 'PAGI::Endpoint::HTTP';
    sub get { PAGI::Response::Text->new('inline') }

    package Local::Inline::Request;
    use parent -norequire, 'PAGI::Request';

    package Local::Inline::Response;
    use parent -norequire, 'PAGI::Response::Text';

    package Local::Inline::Middleware;
    use parent -norequire, 'PAGI::Middleware';
    sub wrap { my ($self, $app) = @_; return $app }

    package Local::Inline::Store;
    sub new { bless {}, shift }
}

# Each loader: how to ask it for a class, the name it is called by in its
# errors, what an inline class of its kind is, and what a file of its kind
# defines before it dies.
my %loader = (
    endpoint => {
        load   => sub { endpoint($_[0]) },
        caller => sub { "endpoint('$_[0]')" },
        inline => 'Local::Inline::Endpoint',
        head   => "use parent 'PAGI::Endpoint::HTTP';\nsub get { PAGI::Response::Text->new('half') }",
    },
    RequestClass => {
        load   => sub { PAGI::Middleware::RequestClass->new(class => $_[0]) },
        caller => sub { 'RequestClass' },
        inline => 'Local::Inline::Request',
        head   => "use parent 'PAGI::Request';",
    },
    response => {
        load   => sub { response("+$_[0]", 'body') },
        caller => sub { "response('+$_[0]')" },
        inline => 'Local::Inline::Response',
        head   => "use parent 'PAGI::Response::Text';",
    },
    middleware => {
        load   => sub { middleware("+$_[0]")->_wrap(sub { }) },
        caller => sub { "middleware('+$_[0]')" },
        inline => 'Local::Inline::Middleware',
        head   => "use parent 'PAGI::Middleware';\nsub wrap { \$_[1] }",
    },
    enable => {
        load   => sub { my $class = shift; builder { enable "+$class"; sub { } } },
        caller => sub { "enable('+$_[0]')" },
        inline => 'Local::Inline::Middleware',
        head   => "use parent 'PAGI::Middleware';\nsub wrap { \$_[1] }",
    },
    session_store => {
        load   => sub { session_store("+$_[0]") },
        caller => sub { "session_store('+$_[0]')" },
        inline => 'Local::Inline::Store',
        head   => 'sub new { bless {}, shift }',
    },
);

my $dir = tempdir(CLEANUP => 1);
unshift @INC, $dir;

for my $name (sort keys %loader) {
    my $l = $loader{$name};
    subtest $name => sub {
        ok(lives { $l->{load}->($l->{inline}) }, 'a class defined in app.pl, with no file, is used as it is')
            or note $@;

        my $missing = "PAGITestLoad::Nowhere::\u$name";
        (my $missing_file = "$missing.pm") =~ s{::}{/}g;
        like(dies { $l->{load}->($missing) },
            qr/\A\Q${\ $l->{caller}->($missing)}\E: cannot load \Q$missing\E: Can't locate \Q$missing_file\E in \@INC/,
            'a class with no file dies, naming the call');

        my $broken = "PAGITestLoad::Broken::\u$name";
        (my $file = "$broken.pm") =~ s{::}{/}g;
        mkdir "$dir/PAGITestLoad";
        mkdir "$dir/PAGITestLoad/Broken";
        open my $fh, '>', "$dir/$file" or die "$dir/$file: $!";
        print {$fh} "package $broken;\n$l->{head}\ndie qq{broken on purpose\\n};\n1;\n";
        close $fh;
        like(dies { $l->{load}->($broken) },
            qr/\A\Q${\ $l->{caller}->($broken)}\E: cannot load \Q$broken\E: broken on purpose/,
            'a file that dies while loading dies, naming the call');
        like(dies { $l->{load}->($broken) },
            qr/\A\Q${\ $l->{caller}->($broken)}\E: cannot load \Q$broken\E: Attempt to reload/,
            'and asking again still dies: what it defined before dying is not used');
    };
}

done_testing;
