package PAGI::Exception::IncompleteResponse;

use strict;
use warnings;
use Carp qw(croak);
use overload q{""} => 'message', fallback => 1;

my %KNOWN_STAGE = map { $_ => 1 }
    qw(before_start after_start body_before_start);

sub new {
    my ($class, @args) = @_;
    croak 'IncompleteResponse options must be key/value pairs'
        if @args % 2;

    my %options = @args;
    for my $key (keys %options) {
        croak "unknown IncompleteResponse option '$key'"
            unless $key eq 'stage' || $key eq 'message';
    }

    croak 'IncompleteResponse stage is required'
        unless defined $options{stage} && !ref($options{stage});
    croak "unknown incomplete response stage '$options{stage}'"
        unless $KNOWN_STAGE{$options{stage}};
    croak 'IncompleteResponse message must be a defined scalar'
        unless defined $options{message} && !ref($options{message});

    return bless {
        stage   => $options{stage},
        message => $options{message},
    }, $class;
}

sub stage   { return $_[0]->{stage} }
sub message { return $_[0]->{message} }

1;

__END__

=head1 NAME

PAGI::Exception::IncompleteResponse - Typed incomplete HTTP response failure

=head1 DESCRIPTION

This throwable records the HTTP lifecycle stage at which a PAGI application
completed without a valid terminal response. It is used by internal application
composition boundaries and stringifies to its diagnostic message.

=head1 SYNOPSIS

    my $error = PAGI::Exception::IncompleteResponse->new(
        stage   => 'after_start',
        message => 'response ended without a terminal body',
    );

    warn $error->stage;
    warn $error->message;
    die $error;

=head1 CONSTRUCTOR

=head2 new

    my $error = PAGI::Exception::IncompleteResponse->new(
        stage   => $stage,
        message => $message,
    );

C<stage> is required and must be exactly C<before_start>, C<after_start>, or
C<body_before_start>. C<message> is required and must be a defined non-reference
scalar. Unknown options, missing values, unknown stages, and reference messages
are rejected. The returned blessed value stringifies to C<message> and can be
thrown directly.

=head1 ACCESSORS

=head2 stage

Returns the validated lifecycle stage.

=head2 message

Returns the original diagnostic scalar. Stringification returns the same value.

=cut
