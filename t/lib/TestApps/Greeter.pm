package TestApps::Greeter;

# A root application, served from its own file.
use v5.24;
use warnings;
use parent 'PAGI::App::Runnable';
use Class::Tiny { greeting => sub { $ENV{GREETING} // 'Hello' } };

our $COMPILED;
BEGIN { $COMPILED++ }

sub call {
    my ($self) = @_;
    return $self->greeting;
}

__PACKAGE__->run_if_script;
