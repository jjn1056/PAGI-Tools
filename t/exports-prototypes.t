use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Middleware::Builder ();
use PAGI::State ();

# The DSL functions with prototypes are imported from the modules that
# declare them, never through PAGI::Tools, which re-exports none of them.
# Each case compiles in a fresh package, so the prototype has to reach the
# importer at compile time for the block syntax to parse.

my $packages = 0;
sub fresh_package { return 'Local::Prototypes::T' . ++$packages }

subtest 'builder, enable, enable_if and mount from PAGI::Middleware::Builder' => sub {
    my $package = fresh_package();
    my $app = eval qq{
        package $package;
        use PAGI::Middleware::Builder;
        builder {
            enable 'ContentLength';
            enable_if { 1 } 'ContentLength';
            mount '/inner' => sub { };
            sub { };
        };
    };
    is($@, '', 'the DSL block compiles and runs');
    is(ref $app, 'CODE', 'builder returns an application coderef');

    no strict 'refs';
    is(prototype(\&{"${package}::builder"}), '&', 'builder takes a block');
    is(prototype(\&{"${package}::enable_if"}), '&$;@', 'enable_if takes a block then a name');
    is(prototype(\&{"${package}::enable"}), undef, 'enable has no prototype');
    is(prototype(\&{"${package}::mount"}), undef, 'mount has no prototype');

    my $outside = fresh_package();
    ok(!eval qq{
        package $outside;
        use PAGI::Middleware::Builder;
        enable 'ContentLength';
        1;
    }, 'enable outside builder dies');
    like($@, qr/\Aenable\(\) must be called inside builder \{\} at \(eval \d+\) line 4\.\n/,
        "naming the caller's line");
};

subtest 'singleton, per_request and factory from PAGI::State' => sub {
    my %class = (
        singleton   => 'PAGI::State::Deferred::Singleton',
        per_request => 'PAGI::State::Deferred::PerRequest',
        factory     => 'PAGI::State::Deferred::Factory',
    );
    for my $name (sort keys %class) {
        my $package = fresh_package();
        my $deferred = eval qq{
            package $package;
            use PAGI::State qw($name);
            $name { 1 };
        };
        is($@, '', "$name { ... } compiles");
        isa_ok($deferred, [$class{$name}], "$name builds its lifetime");
        no strict 'refs';
        is(prototype(\&{"${package}::$name"}), '&', "$name takes a block");
    }
};

subtest 'the DSL functions are not methods' => sub {
    ok(!PAGI::Middleware::Builder->can($_), "a Builder has no $_ method")
        for qw(builder enable enable_if mount);
    ok(!PAGI::State->can($_), "a State has no $_ method")
        for qw(app_state singleton per_request factory);
};

subtest "Builder's object interface" => sub {
    my $builder = PAGI::Middleware::Builder->new;
    ok(lives { $builder->add_middleware('ContentLength') }, 'add_middleware');
    ok(lives { $builder->add_middleware_if(sub { 1 }, 'ContentLength') }, 'add_middleware_if');
    ok(lives { $builder->add_mount('/inner' => sub { }) }, 'add_mount');
    is(ref $builder->to_app(sub { }), 'CODE', 'to_app builds the application');
};

subtest "Builder's POD names the object interface's methods" => sub {
    my $file = $INC{'PAGI/Middleware/Builder.pm'};
    open my $fh, '<', $file or die "cannot read $file: $!";
    my $source = do { local $/; <$fh> };
    my ($synopsis) = $source =~ /^=head1 SYNOPSIS\n(.*?)^=head1 /ms;
    ok(defined $synopsis, 'there is a SYNOPSIS');
    unlike($synopsis, qr/\$builder->(?:enable|enable_if|mount)\(/,
        'the SYNOPSIS calls no DSL name as a method');
    like($synopsis, qr/\$builder->add_middleware\(/, 'it shows add_middleware');
    like($synopsis, qr/\$builder->add_mount\(/, 'it shows add_mount');

    my %heading;
    $heading{$1}++ while $source =~ /^=head2 (\S+)/mg;
    is($heading{$_}, 1, "one =head2 $_") for qw(enable enable_if mount);
    is($heading{$_}, 1, "one =head2 $_")
        for qw(add_middleware add_middleware_if add_mount);
};

done_testing;
