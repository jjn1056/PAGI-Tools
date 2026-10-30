use strict;
use warnings;
use Test2::V0;

use PAGI::Utils::_SetCookie ();

sub bake { PAGI::Utils::_SetCookie::set_cookie_string(@_) }

# Fixtures generated once from Cookie::Baker 0.12 bake_cookie with the value
# 'plain123' (an encoding-neutral value) and a fixed epoch expires, so the
# attribute spelling, order and date format are pinned without the module.
my @attribute_cases = (
    [ 'no attributes',     {},                              'sid=plain123' ],
    [ 'path',              { path => '/app' },              'sid=plain123; path=/app' ],
    [ 'domain',            { domain => 'example.com' },     'sid=plain123; domain=example.com' ],
    [ 'expires',           { expires => 1700000000 },       'sid=plain123; expires=Tue, 14-Nov-2023 22:13:20 GMT' ],
    [ 'expires 0',         { expires => 0 },                'sid=plain123; expires=Thu, 01-Jan-1970 00:00:00 GMT' ],
    [ 'max-age',           { 'max-age' => 3600 },           'sid=plain123; max-age=3600' ],
    [ 'max-age 0',         { 'max-age' => 0 },              'sid=plain123; max-age=0' ],
    [ 'samesite lax',      { samesite => 'lax' },           'sid=plain123; SameSite=Lax' ],
    [ 'samesite Strict',   { samesite => 'Strict' },        'sid=plain123; SameSite=Strict' ],
    [ 'samesite NONE',     { samesite => 'NONE' },          'sid=plain123; SameSite=None; secure' ],
    [ 'samesite unknown',  { samesite => 'bogus' },         'sid=plain123' ],
    [ 'secure',            { secure => 1 },                 'sid=plain123; secure' ],
    [ 'httponly',          { httponly => 1 },               'sid=plain123; HttpOnly' ],
    [ 'partitioned',       { partitioned => 1 },            'sid=plain123; SameSite=None; secure; Partitioned' ],
    [ 'everything',
      { domain => 'example.com', path => '/app', expires => 1700000000, 'max-age' => 3600,
        samesite => 'Strict', secure => 1, httponly => 1 },
      'sid=plain123; domain=example.com; path=/app; expires=Tue, 14-Nov-2023 22:13:20 GMT; max-age=3600; SameSite=Strict; secure; HttpOnly' ],
);

subtest 'attributes are spelled and ordered as Cookie::Baker 0.12 did' => sub {
    for my $case (@attribute_cases) {
        my ($label, $attrs, $expected) = @$case;
        is bake('sid', 'plain123', %$attrs), $expected, $label;
    }
};

subtest 'a token name is written as is and reads back' => sub {
    require PAGI::HTTPConnection;
    for my $name ('session_id', '__Host-x', 'a.b', "!#\$%&'*+-.^_`|~09azAZ") {
        my $line = bake($name, 'v');
        is $line, "$name=v", "$name written as is";
        my $conn = PAGI::HTTPConnection->new({ type => 'http', path => '/', headers => [['cookie', $line]] });
        is $conn->cookies, { $name => 'v' }, "$name reads back under the same name";
    }
};

subtest 'a name that is not a cookie-name token croaks, naming the character' => sub {
    for my $char (split //, " \t\"(),/:;<=>?\@[\\]{}\x00\x1F\x7F\xE9") {
        my $label = sprintf 'U+%04X', ord $char;
        like dies { bake("a${char}b", 'v') },
            qr/\Acookie name contains '\Q$char\E' which is not allowed in a cookie name/,
            "$label refused";
    }
    like dies { bake('', 'v') }, qr/\Acookie name must not be empty/, 'an empty name croaks';
};

subtest 'an undefined value croaks, without a warning' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    like dies { bake('a', undef) }, qr/\Acookie value must be defined/, 'undef value refused';
    is \@warnings, [], 'no warning';
};

subtest 'an unknown samesite value is omitted, a prefix of a known one is not accepted' => sub {
    is bake('a', 'v', samesite => 'Laxity'), 'a=v', 'Laxity writes no SameSite';
    is bake('a', 'v', samesite => 'Strictly'), 'a=v', 'Strictly writes no SameSite';
};

subtest 'a cookie-octet value is written as is' => sub {
    is bake('a', 'x/y'), 'a=x/y', 'slash';
    is bake('a', 'x%y'), 'a=x%y', 'percent';
    is bake('a', 'a+b'), 'a=a+b', 'plus';
    is bake('a', ''),    'a=',    'empty';
    my $all = join '', map chr, 0x21, 0x23 .. 0x2B, 0x2D .. 0x3A, 0x3C .. 0x5B, 0x5D .. 0x7E;
    is bake('a', $all), "a=$all", 'every RFC 6265 cookie-octet';
};

subtest 'every other character croaks, naming it' => sub {
    my %refused = (
        ';'    => ";",
        ','    => ',',
        ' '    => ' ',
        '"'    => '"',
        '\\'   => '\\',
        "\t"   => "\t",
        "\x00" => "\x00",
        "\x7F" => "\x7F",
        "\xE9" => "\xE9",
    );
    for my $char (sort keys %refused) {
        my $label = sprintf 'U+%04X', ord $char;
        like dies { bake('a', "x${char}y") },
            qr/\Acookie value contains '\Q$char\E' which browsers cannot carry; encode it first \(Base64, say\)/,
            "$label refused";
    }
};

done_testing;
