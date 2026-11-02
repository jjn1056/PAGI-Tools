package PAGI::Utils::_Exporter;

use strict;
use warnings;

=head1 NAME

PAGI::Utils::_Exporter - Private installer for PAGI-Tools' exported functions

=head1 DESCRIPTION

Private to PAGI-Tools; not a public interface. A PAGI-Tools module's
C<import> calls C<export> to install the functions it declares into the
importing package.

=head2 export

    PAGI::Utils::_Exporter::export(
        $module, \%exports, \%tags, \@defaults,
        $target, $invocant, @requested,
    );

The arguments are:

=over 4

=item * C<$module> -- the declaring package (C<__PACKAGE__>).

=item * C<\%exports> -- name to coderef.

=item * C<\%tags> -- tag name to an arrayref of names.

=item * C<\@defaults> -- the names a bare C<use Module;> installs.

=item * C<$target> -- the importing package.

=item * C<$invocant> -- what C<import> was called on.

=item * C<@requested> -- the import list: names, and tags written C<:tag>.

=back

An empty import list installs C<@defaults>. Each name is installed as the
declared coderef itself, never a wrapper, so C<caller> inside it, Carp's
attribution and its prototype behave as if the importer had defined it.
Installing the coderef a name already holds does nothing.

A subclass exports nothing: when C<$invocant> is not C<$module>, nothing is
installed, and a non-empty import list croaks
C<< <invocant> exports nothing; import from <module> >>. An unknown name or
tag croaks C<< "<name>" is not exported by <module> >>, as does a tag listing
a name C<\%exports> does not declare. Both messages end with the file and
line of the user's C<use>.

Returns nothing.

=cut

# Installs a module's declared coderefs into the importing package. The
# coderef itself is installed, never a wrapper, so caller() inside it, Carp
# attribution and prototypes behave as if the importer had defined it.
sub export {
    my ($module, $exports, $tags, $defaults, $target, $invocant, @requested) = @_;

    if ($invocant ne $module) {
        _fail(2, "$invocant exports nothing; import from $module") if @requested;
        return;
    }

    my @names = @requested
        ? map { _expand($module, $exports, $tags, $_) } @requested
        : @$defaults;

    no strict 'refs';
    for my $name (@names) {
        my $code = $exports->{$name};
        my $symbol = "${target}::$name";
        next if defined &$symbol && \&$symbol == $code;
        *$symbol = $code;
    }
    return;
}

sub _expand {
    my ($module, $exports, $tags, $item) = @_;
    if ($item =~ /\A:(.+)\z/) {
        my $names = $tags->{$1}
            or _fail(3, qq{"$item" is not exported by $module});
        $exports->{$_} or _fail(3, qq{"$_" is not exported by $module})
            for @$names;
        return @$names;
    }
    _fail(3, qq{"$item" is not exported by $module}) unless $exports->{$item};
    return $item;
}

# Reports at the user's `use` line: `use` calls the module's import, which
# calls export(), so that line is $depth frames above _fail -- 2 from
# export(), 3 from _expand().
sub _fail {
    my ($depth, $message) = @_;
    my (undef, $file, $line) = caller($depth);
    die "$message at $file line $line.\n";
}

1;
