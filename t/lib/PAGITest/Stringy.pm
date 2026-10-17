package PAGITest::Stringy;

use strict;
use warnings;

use Future;
use Test2::V0;

# The stringification rule, checked the same way at every site that takes a
# string: an object whose class overloads "" (directly or through a parent)
# stands for its string, stringified once; every other value that is not a
# plain string is refused with the site's own message.

{ package PAGITest::Stringy::Overloaded;
  use overload '""' => sub { $_[0]{string} }, fallback => 1;
  sub new { my ($class, $string) = @_; bless { string => $string }, $class } }
{ package PAGITest::Stringy::Counting;
  use overload '""' => sub { $_[0]{calls}++; $_[0]{string} }, fallback => 1;
  sub new { my ($class, $string) = @_; bless { string => $string, calls => 0 }, $class } }
{ package PAGITest::Stringy::Inherited;
  our @ISA = ('PAGITest::Stringy::Overloaded'); }
{ package PAGITest::Stringy::NumberOnly;
  use overload '0+' => sub { 42 }, fallback => 1;
  sub new { bless {}, shift } }
{ package PAGITest::Stringy::BoolOnly;
  use overload 'bool' => sub { 1 }, fallback => 1;
  sub new { bless {}, shift } }
{ package PAGITest::Stringy::Undefined;
  use overload '""' => sub { undef };
  sub new { bless {}, shift } }
{ package PAGITest::Stringy::Dies;
  use overload '""' => sub { die "stringify refused\n" };
  sub new { bless {}, shift } }
{ package PAGITest::Stringy::Plain;
  sub new { bless {}, shift } }

# The events a response sends as an http application.
sub events_of {
    my ($response) = @_;
    my @events;
    $response->to_app->(
        { type => 'http' },
        sub { Future->done },
        sub { push @events, $_[0]; Future->done },
    )->get;
    return \@events;
}

# The body a response sends.
sub body_of {
    my ($response) = @_;
    return join '', map { $_->{body} // '' }
        grep { $_->{type} eq 'http.response.body' } @{ events_of($response) };
}

# run => sub { my ($value) = @_; ... return the string the site sent },
# refused => the site's own error for a value that is not a string, and
# string => the string the objects give (default 'ok'), for sites that need
# a particular form, such as an absolute URI.
sub check_site {
    my (%args) = @_;
    my ($name, $run, $refused) = @args{qw(name run refused)};
    my $string = $args{string} // 'ok';
    subtest "$name follows the stringification rule" => sub {
        is($run->(PAGITest::Stringy::Overloaded->new($string)), $string, 'an overloading object');
        is($run->(PAGITest::Stringy::Inherited->new($string)), $string, 'an inherited overload');

        my $counting = PAGITest::Stringy::Counting->new($string);
        $run->($counting);
        is($counting->{calls}, 1, 'stringified once');

        for my $refusal (
            [ 'a number-only overload', PAGITest::Stringy::NumberOnly->new ],
            [ 'a bool-only overload',   PAGITest::Stringy::BoolOnly->new ],
            [ 'a plain object',         PAGITest::Stringy::Plain->new ],
            [ 'a hash reference',       {} ],
            [ 'undef',                  undef ],
        ) {
            my ($label, $value) = @$refusal;
            like(dies { $run->($value) }, $refused, "$label is refused");
        }

        my @warnings;
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            like(dies { $run->(PAGITest::Stringy::Undefined->new) }, $refused,
                'an overload returning undef is refused');
        }
        is(\@warnings, [], 'without a warning');

        like(dies { $run->(PAGITest::Stringy::Dies->new) }, qr/\Astringify refused/,
            "the object's own exception propagates");
    };
}

1;
