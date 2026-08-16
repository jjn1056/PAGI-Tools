package PAGI::App::File::Result;

use strict;
use warnings;
use Carp qw(croak);

my %VALID_KIND = map { $_ => 1 } qw(file directory missing forbidden);
my %VALID_ARGUMENT = map { $_ => 1 } qw(kind path size mtime);

sub new {
    my $class = shift;
    croak 'Result constructor requires key/value arguments' if @_ % 2;
    my %args = @_;

    for my $name (keys %args) {
        croak "Unknown Result constructor argument '$name'"
            unless $VALID_ARGUMENT{$name};
    }

    my $kind = $args{kind};
    croak 'Result kind must be one of: file, directory, missing, forbidden'
        unless defined($kind) && !ref($kind) && $VALID_KIND{$kind};
    croak 'Result path must be an undefined value or a non-reference string'
        if defined($args{path}) && ref($args{path});
    croak 'Result size must be an undefined value or a non-reference scalar'
        if defined($args{size}) && ref($args{size});
    croak 'Result mtime must be an undefined value or a non-reference scalar'
        if defined($args{mtime}) && ref($args{mtime});
    if ($kind eq 'file') {
        croak 'File Result requires a defined path, size, and mtime'
            unless defined($args{path})
                && defined($args{size}) && defined($args{mtime});
    }
    else {
        croak 'Non-file Result must not specify size or mtime'
            if exists($args{size}) || exists($args{mtime});
    }

    return bless [
        $kind, $args{path}, $args{size}, $args{mtime},
    ], $class;
}

sub _read {
    my ($self, $offset, $name, @arguments) = @_;
    croak "Result $name is read-only" if @arguments;
    return $self->[$offset];
}

sub kind  { return _read($_[0], 0, 'kind',  @_[1 .. $#_]) }
sub path  { return _read($_[0], 1, 'path',  @_[1 .. $#_]) }
sub size  { return _read($_[0], 2, 'size',  @_[1 .. $#_]) }
sub mtime { return _read($_[0], 3, 'mtime', @_[1 .. $#_]) }

sub is_file      { return $_[0]->kind eq 'file'      ? 1 : 0 }
sub is_directory { return $_[0]->kind eq 'directory' ? 1 : 0 }
sub is_missing   { return $_[0]->kind eq 'missing'   ? 1 : 0 }
sub is_forbidden { return $_[0]->kind eq 'forbidden' ? 1 : 0 }

=head1 NAME

PAGI::App::File::Result - Request-local file location result

=head1 DESCRIPTION

C<PAGI::App::File::Result> is the read-only value returned by
L<PAGI::App::File/locate>.  A Result belongs to one location attempt; it has
no shared mutable state.

=head1 METHODS

=head2 kind

Returns C<file>, C<directory>, C<missing>, or C<forbidden>.

=head2 path

Returns the lexical filesystem candidate.  It may be undefined when unsafe
request input prevented construction of a candidate.  A path does not by
itself imply authorization.

=head2 size

Returns the size captured while locating a file.  It is undefined for other
result kinds.

=head2 mtime

Returns the modification time captured while locating a file.  It is
undefined for other result kinds.

=head2 is_file

Returns true when L</kind> is C<file>.

=head2 is_directory

Returns true when L</kind> is C<directory>.

=head2 is_missing

Returns true when L</kind> is C<missing>.

=head2 is_forbidden

Returns true when L</kind> is C<forbidden>.

=cut

1;
