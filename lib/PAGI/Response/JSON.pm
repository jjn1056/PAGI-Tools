package PAGI::Response::JSON;

use strict;
use warnings;

use Exporter qw(import);
use JSON::MaybeXS ();
use parent 'PAGI::Response';

=encoding UTF-8

=head1 NAME

PAGI::Response::JSON - buffered UTF-8 JSON response

=head1 SYNOPSIS

    use PAGI::Response::JSON qw(json_response);
    my $response = PAGI::Response::JSON->new({ ok => \1 });
    my $same = json_response({ ok => \1 });

=head1 DESCRIPTION

Buffers one JSON::MaybeXS-compatible finite Perl value as UTF-8 JSON bytes
with C<application/json>. Common C<status>, flat C<headers>, and
C<content_type> options are accepted. Object member order is unspecified and
is not a byte-stability contract. Signatures, hashes, and canonical caches
need an application Response subclass with an explicitly canonical encoder.

=cut

our @EXPORT_OK = qw(json_response);

my $JSON = JSON::MaybeXS->new(utf8 => 1);

sub json_response {
    return PAGI::Response::JSON->new(@_);
}

sub default_content_type { 'application/json' }

sub render {
    my ($self, $value) = @_;
    return $JSON->encode($value);
}

1;
