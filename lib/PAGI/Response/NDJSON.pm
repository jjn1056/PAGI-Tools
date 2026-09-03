package PAGI::Response::NDJSON;

use strict;
use warnings;

use Carp qw(croak);
use Exporter qw(import);
use parent 'PAGI::Response::Stream';
use PAGI::Response::NDJSON::Writer ();

our @EXPORT_OK = qw(ndjson_response);

sub ndjson_response {
    return PAGI::Response::NDJSON->new(@_);
}

sub default_content_type { 'application/x-ndjson' }

sub new {
    my ($class, $producer, @response_options) = @_;
    croak 'PAGI::Response::NDJSON->new requires a producer coderef'
        unless @_ >= 2 && ref($producer) eq 'CODE';

    my $adapted = sub {
        my ($writer) = @_;
        return $producer->(
            PAGI::Response::NDJSON::Writer->_new($writer)
        );
    };

    return $class->SUPER::new($adapted, @response_options);
}

1;
