use strict;
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

subtest 'attributes: list or hashref, defaults, lazy code defaults' => sub {
    is(Local::Hello->new({ greeting => 'Hey' })->greeting, 'Hey', 'a hashref');
    is(Local::Hello->new->greeting, 'Hello', 'a default');
    local $ENV{HELLO_NAME} = 'John';
    is(Local::Hello->new->name, 'John', 'a code default runs on first use');
};

subtest 'a subclass without call croaks when called' => sub {
    my $app = Local::NoCall->new->to_app;
    like(dies { $app->() }, qr/\ALocal::NoCall must implement "call" or override "to_app" at /,
        'names the class');
};

done_testing;
