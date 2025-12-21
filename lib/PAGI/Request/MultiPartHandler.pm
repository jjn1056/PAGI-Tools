package PAGI::Request::MultiPartHandler;
use strict;
use warnings;

use Future::AsyncAwait;
use HTTP::MultiPartParser;
use Hash::MultiValue;
use PAGI::Request::Upload;
use File::Temp qw(tempfile);

# Default limits
our $MAX_PART_SIZE    = 10 * 1024 * 1024;  # 10MB per part
our $SPOOL_THRESHOLD  = 64 * 1024;          # 64KB before spooling to disk
our $MAX_FILES        = 20;
our $MAX_FIELDS       = 1000;

sub new {
    my ($class, %args) = @_;

    return bless {
        boundary        => $args{boundary},
        receive         => $args{receive},
        max_part_size   => $args{max_part_size}   // $MAX_PART_SIZE,
        spool_threshold => $args{spool_threshold} // $SPOOL_THRESHOLD,
        max_files       => $args{max_files}       // $MAX_FILES,
        max_fields      => $args{max_fields}      // $MAX_FIELDS,
        temp_dir        => $args{temp_dir}        // $ENV{TMPDIR} // '/tmp',
    }, $class;
}

async sub parse {
    my $self = shift;

    my @form_pairs;
    my @upload_pairs;
    my $file_count = 0;
    my $field_count = 0;

    # Current part state
    my $current_headers;
    my $current_data = '';
    my $current_fh;
    my $current_temp_path;
    my $current_size = 0;

    my $finish_part = sub {
        return unless $current_headers;

        my $disposition = _parse_content_disposition($current_headers);
        my $name = $disposition->{name} // '';
        my $filename = $disposition->{filename};
        my $content_type = $current_headers->{'content-type'} // 'text/plain';

        if (defined $filename) {
            # File upload
            $file_count++;
            die "Too many files (max $self->{max_files})"
                if $file_count > $self->{max_files};

            my $upload;
            if ($current_fh) {
                close $current_fh;
                $upload = PAGI::Request::Upload->new(
                    field_name   => $name,
                    filename     => $filename,
                    content_type => $content_type,
                    temp_path    => $current_temp_path,
                    size         => $current_size,
                );
            } else {
                $upload = PAGI::Request::Upload->new(
                    field_name   => $name,
                    filename     => $filename,
                    content_type => $content_type,
                    data         => $current_data,
                );
            }
            push @upload_pairs, $name, $upload;
        } else {
            # Regular form field
            $field_count++;
            die "Too many fields (max $self->{max_fields})"
                if $field_count > $self->{max_fields};

            push @form_pairs, $name, $current_data;
        }

        # Reset state
        $current_headers = undef;
        $current_data = '';
        $current_fh = undef;
        $current_temp_path = undef;
        $current_size = 0;
    };

    my $parser = HTTP::MultiPartParser->new(
        boundary => $self->{boundary},

        on_header => sub {
            my ($headers) = @_;
            $finish_part->();  # Finish previous part if any

            # Parse headers into hash - $headers is an arrayref of header lines
            $current_headers = {};
            for my $line (@$headers) {
                if ($line =~ /^([^:]+):\s*(.*)$/) {
                    $current_headers->{lc($1)} = $2;
                }
            }
        },

        on_body => sub {
            my ($chunk) = @_;
            $current_size += length($chunk);

            die "Part too large (max $self->{max_part_size} bytes)"
                if $current_size > $self->{max_part_size};

            # Check if we need to spool to disk
            if (!$current_fh && $current_size > $self->{spool_threshold}) {
                # Spool to temp file
                ($current_fh, $current_temp_path) = tempfile(
                    DIR    => $self->{temp_dir},
                    UNLINK => 0,
                );
                binmode($current_fh);
                print $current_fh $current_data;
                $current_data = '';
            }

            if ($current_fh) {
                print $current_fh $chunk;
            } else {
                $current_data .= $chunk;
            }
        },

        on_error => sub {
            my ($error) = @_;
            die "Multipart parse error: $error";
        },
    );

    # Feed chunks from receive
    my $receive = $self->{receive};
    while (1) {
        my $message = await $receive->();
        last unless $message && $message->{type};
        last if $message->{type} eq 'http.disconnect';

        if (defined $message->{body} && length $message->{body}) {
            $parser->parse($message->{body});
        }

        last unless $message->{more};
    }

    $parser->finish;
    $finish_part->();  # Handle last part

    return (
        Hash::MultiValue->new(@form_pairs),
        Hash::MultiValue->new(@upload_pairs),
    );
}

sub _parse_content_disposition {
    my ($headers) = @_;
    my $cd = $headers->{'content-disposition'} // '';

    my %result;

    # Parse name="value" pairs
    while ($cd =~ /(\w+)="([^"]*)"/g) {
        $result{$1} = $2;
    }
    # Also handle unquoted values
    while ($cd =~ /(\w+)=([^;\s"]+)/g) {
        $result{$1} //= $2;
    }

    return \%result;
}

1;

__END__

=head1 NAME

PAGI::Request::MultiPartHandler - Async multipart/form-data parser

=head1 SYNOPSIS

    my $handler = PAGI::Request::MultiPartHandler->new(
        boundary => $boundary,
        receive  => $receive,
    );

    my ($form, $uploads) = await $handler->parse;

=cut
