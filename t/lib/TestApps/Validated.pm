package TestApps::Validated;

# A root application with a setting it can't run without, checked in BUILD.
use v5.24;
use warnings;
use parent 'PAGI::App::Runnable';
use Class::Tiny { dsn => sub { $ENV{VALIDATED_DSN} } };

sub BUILD {
    my ($self) = @_;
    die "TestApps::Validated needs a database: set VALIDATED_DSN\n" unless defined $self->dsn;
}

sub call {
    my ($self) = @_;
    return $self->dsn;
}

__PACKAGE__->run_if_script;
