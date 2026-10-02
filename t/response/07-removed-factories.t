use strict;
use warnings;
use Test2::V0;
use File::Find;

# The nine NAME_response factories were replaced by response('Name', ...).
# Both spellings of response() are valid Perl, so a leftover
# response($bytes) would silently build the wrong thing: every response(
# call must name a class.
# Skipped: this file; the export test, which proves a removed name cannot be
# imported; the builder test, which calls response() with bad arguments.
my %skip = map { $_ => 1 } qw(
    t/response/07-removed-factories.t
    t/response-convenience.t
    t/response/06-builder.t
);
my $removed = qr/\b(?:text|html|json|problem|redirect|empty|file|stream|ndjson)_response\b/;
my $unnamed = qr/(?<![\w>:\$])response\(\s*(?!['"]|\$name\b|\))/;

my (@removed, @unnamed);
find({ no_chdir => 1, wanted => sub {
    return unless -f $_ && !$skip{$_};
    open my $fh, '<', $_ or die "$_: $!";
    while (my $line = <$fh>) {
        push @removed, "$_:$.: $line" if $line =~ $removed;
        push @unnamed, "$_:$.: $line" if $line =~ $unnamed;
    }
}}, grep { -e } qw(lib t examples README.md UPGRADING.md UPGRADING-REFERENCE.md));

is(\@removed, [], 'no removed NAME_response factory is named anywhere');
is(\@unnamed, [], 'every response( call names a class');

done_testing;
