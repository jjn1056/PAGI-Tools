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

    my $response = PAGI::Response::JSON->new({ ok => \1 });

=head1 DESCRIPTION

Encodes one JSON::MaybeXS-compatible Perl value as UTF-8 JSON bytes.  Object
member order is intentionally not canonicalized.

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
