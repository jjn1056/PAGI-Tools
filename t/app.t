use v5.24;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use PAGI::App;

package Local::Hello {
    use parent 'PAGI::App';
    use Class::Tiny { greeting => 'Hello', name => sub { $ENV{HELLO_NAME} // 'nobody' } };
    sub call { my ($self, @args) = @_; return [$self->greeting, $self->name, scalar @args] }
}

package Local::NoCall {
    use parent 'PAGI::App';
}

subtest 'to_app returns a code reference that calls call' => sub {
    my $app = Local::Hello->new(greeting => 'Hi')->to_app;
    is(ref $app, 'CODE', 'a code reference');
    is($app->('scope', 'receive', 'send'), ['Hi', 'nobody', 3], 'call gets ($scope, $receive, $send)');
};

subtest 'attributes: defaults, lazy code defaults' => sub {
    is(Local::Hello->new->greeting, 'Hello', 'a default');
    local $ENV{HELLO_NAME} = 'John';
    is(Local::Hello->new->name, 'John', 'a code default runs on first use');
};

subtest 'a subclass without call croaks when called' => sub {
    my $app = Local::NoCall->new->to_app;
    like(dies { $app->() }, qr/\ALocal::NoCall must implement "call" or override "to_app" at /,
        'names the class');
};

subtest 'a Moose subclass, through MooseX::NonMoose, runs BUILD once' => sub {
    skip_all 'needs Moose and MooseX::NonMoose'
        unless eval { require Moose; require MooseX::NonMoose; 1 };
    our $builds = 0;
    eval q{
        package Local::MooseHello;
        use Moose;
        use MooseX::NonMoose;
        extends 'PAGI::App';
        has name => (is => 'ro', required => 1);
        sub BUILD { $main::builds++ }
        sub call { my ($self) = @_; return $self->name }
        __PACKAGE__->meta->make_immutable;
        1;
    } or die $@;
    my $app = Local::MooseHello->new(name => 'Ann');
    is($builds, 1, 'BUILD runs once');
    is($app->to_app->(), 'Ann', 'the arguments are set, and to_app calls call');
    like(dies { Local::MooseHello->new }, qr/Attribute \(name\) is required/, 'required is checked');
};

done_testing;
