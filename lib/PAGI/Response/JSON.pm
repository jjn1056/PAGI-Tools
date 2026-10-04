package PAGI::Response::JSON;

use strict;
use warnings;

use JSON::MaybeXS ();
use parent 'PAGI::Response';

=encoding UTF-8

=head1 NAME

PAGI::Response::JSON - buffered UTF-8 JSON response

=head1 SYNOPSIS

    use PAGI::Response qw(response);
    my $response = response('JSON', { ok => \1 });

    # The same, by class -- what response() calls:
    use PAGI::Response::JSON;
    my $same = PAGI::Response::JSON->new({ ok => \1 });

=head1 DESCRIPTION

Buffers one JSON::MaybeXS-compatible finite Perl value as UTF-8 JSON bytes
with C<application/json>. Common C<status>, flat C<headers>, and
C<content_type> options are accepted. Object member order is unspecified and
is not a byte-stability contract. Signatures, hashes, and canonical caches
need an application Response subclass with an explicitly canonical encoder.

=cut

my $JSON = JSON::MaybeXS->new(utf8 => 1);

sub default_content_type { 'application/json' }

sub render {
    my ($self, $value) = @_;
    return $JSON->encode($value);
}

1;
