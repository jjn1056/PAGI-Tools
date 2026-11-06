package TestApps::Commands;

# A root application with a command of its own.
use v5.24;
use warnings;
use parent 'PAGI::App::Runnable';

sub call { return 'commands' }

sub run {
    my ($self, @args) = @_;
    if (($args[0] // '') eq 'hello') {
        print "hello from run\n";
        return 0;
    }
    return $self->SUPER::run(@args);
}

__PACKAGE__->run_if_script;
