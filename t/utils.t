use v5.24;
use warnings;
use Test2::V0;

use PAGI::Utils;

package Local::Name {
    use overload '""' => sub { 'Ada' }, fallback => 1;
    sub new { bless {}, shift }
}

subtest 'as_string: strings, numbers and objects that stringify' => sub {
    is PAGI::Utils::as_string('hello', 'name'), 'hello', 'a string';
    is PAGI::Utils::as_string(42, 'name'), '42', 'a number, as a string';
    is PAGI::Utils::as_string(Local::Name->new, 'name'), 'Ada', 'an object that stringifies: its string';
    ok !ref PAGI::Utils::as_string(Local::Name->new, 'name'), 'a plain string, not the object';
    is PAGI::Utils::as_string(undef, 'name'), undef, 'undef stays undef';
};

subtest 'as_string: any other reference dies, naming the argument' => sub {
    for my $value ([], {}, sub { 1 }, \'x', bless({}, 'Local::Plain')) {
        like dies { PAGI::Utils::as_string($value, 'filename') },
            qr/\Afilename must be a string, or an object that stringifies at \Q${\ __FILE__}\E line/,
            ref $value;
    }
};

done_testing;
