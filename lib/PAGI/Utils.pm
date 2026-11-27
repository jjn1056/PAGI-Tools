package PAGI::Utils;

use v5.24;
use warnings;
use Carp ();
use overload ();

# The classes that call these on your behalf, so a croak names your line,
# not theirs: Carp skips the frames of a package this trusts. Carp's trust
# runs up @ISA from a subclass, not down, so each calling class is named;
# add a class here when it calls these (its tests' "at your line" checks
# fail until it is).
our @CARP_NOT = qw(PAGI::Response PAGI::Response::Text PAGI::Response::File PAGI::Response::Redirect);

# A value as a string: a string as it is, an object that overloads
# stringification as its string, undef as undef. Any other reference
# croaks, naming the argument.
sub as_string {
    my ($value, $name) = @_;
    return undef unless defined $value;
    Carp::croak("$name must be a string, or an object that stringifies")
        if ref $value && !overload::Method($value, '""');
    return "$value";
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Utils - Small functions the rest of PAGI::Tools shares

=head1 SYNOPSIS

    use PAGI::Utils;

    my $path = PAGI::Utils::as_string($args{path}, 'path');

=head1 DESCRIPTION

Plain functions, not methods, and nothing is exported: call each by its full
name.

=head1 FUNCTIONS

=head2 as_string

    my $string = PAGI::Utils::as_string($value, $name);

C<$value> as a string: a string or a number as it is, an object that
overloads stringification (a L<URI>, a L<Path::Tiny>) as its string, and
C<undef> as C<undef>. Any other reference, a hash or array reference say, or
an object that doesn't stringify, dies, naming the argument:

    path must be a string, or an object that stringifies

Interpolating a reference wouldn't die: it would make a string like
C<HASH(0x7fc1ad00aca8)>, and send that. This is how PAGI::Tools' responses
check the text, paths and URLs you give them, and the error names your
line.

=head1 SEE ALSO

L<PAGI::Response>

=cut
