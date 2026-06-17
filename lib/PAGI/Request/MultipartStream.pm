package PAGI::Request::MultipartStream;
use strict;
use warnings;

use Future::AsyncAwait;
use Carp qw(croak);
use HTTP::MultiPartParser;

=head1 NAME

PAGI::Request::MultipartStream - Pull-based streaming multipart/form-data engine

=head1 SYNOPSIS

    use PAGI::Request::MultipartStream;
    use Future::AsyncAwait;

    my $stream = PAGI::Request::MultipartStream->new(
        receive  => $receive,
        boundary => $boundary,
    );

    while (defined(my $part = await $stream->next)) {
        printf "%s part: name=%s\n", $part->type, $part->name;
    }

=head1 DESCRIPTION

Drives L<HTTP::MultiPartParser> on demand, bridging its push-based callbacks
to a pull-based interface over an internal event queue. Each part is exposed
as a L<PAGI::Request::Part> via C<next>; the application streams each part to
its own sink instead of the auto-spool-to-temp-file behaviour of the buffered
multipart handler.

=cut

our $MAX_FILES        = 1000;
our $MAX_FIELDS       = 1000;
our $MAX_FIELD_SIZE   = 1024 * 1024;          # buffered per-field cap
our $MAX_FILE_SIZE    = 100 * 1024 * 1024;
our $MAX_REQUEST_BODY = 1024 * 1024 * 1024;   # defense-in-depth; server max_body_size is primary

=head1 CONSTRUCTOR

=head2 new

    my $stream = PAGI::Request::MultipartStream->new(
        receive  => $receive,   # required: PAGI receive callback
        boundary => $boundary,  # required: multipart boundary
    );

Creates a new streaming multipart engine.

=cut

sub new {
    my ($class, %args) = @_;
    croak "receive is required"  unless $args{receive};
    croak "boundary is required" unless defined $args{boundary} && length $args{boundary};
    my $self = bless {
        receive          => $args{receive},
        boundary         => $args{boundary},
        max_files        => $args{max_files}        // $MAX_FILES,
        max_fields       => $args{max_fields}       // $MAX_FIELDS,
        max_field_size   => $args{max_field_size}   // $MAX_FIELD_SIZE,
        max_file_size    => $args{max_file_size}    // $MAX_FILE_SIZE,
        max_request_body => $args{max_request_body} // $MAX_REQUEST_BODY,
        _queue       => [],        # FIFO: ['part',\%meta] | ['body',$chunk]
        _file_count  => 0,
        _field_count => 0,
        _bytes_total => 0,
        _cur_is_file => 0,
        _cur_bytes   => 0,
        _current     => undef,     # current Part
        _exhausted   => 0,
        _disconnect  => 0,
        _failed      => undef,     # sticky failure message (poisons the stream)
    }, $class;
    $self->{_parser} = $self->_build_parser;
    return $self;
}

# Parse the on_header arrayref of header lines into
# {name,filename,content_type,encoding,headers}. is_file := defined(filename).
sub _disposition {
    my ($lines) = @_;

    # $lines is an arrayref of raw header lines, e.g.
    # 'Content-Disposition: form-data; name="x"'
    my %headers;
    for my $line (@$lines) {
        if ($line =~ /^([^:]+):\s*(.*)$/) {
            $headers{lc($1)} = $2;
        }
    }

    my $disposition = _parse_content_disposition(\%headers);

    return {
        name         => $disposition->{name},
        filename     => $disposition->{filename},
        content_type => $headers{'content-type'} // 'text/plain',
        encoding     => $headers{'content-transfer-encoding'},
        headers      => \%headers,
    };
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

sub _build_parser {
    my ($self) = @_;
    return HTTP::MultiPartParser->new(
        boundary  => $self->{boundary},
        on_header => sub {
            my ($headers) = @_;
            return if $self->{_failed};
            my $meta = _disposition($headers);
            my $is_file = defined $meta->{filename} ? 1 : 0;
            if ($is_file) {
                $self->{_failed} = "Too many file parts (max $self->{max_files})"
                    if ++$self->{_file_count} > $self->{max_files};
            } else {
                $self->{_failed} = "Too many field parts (max $self->{max_fields})"
                    if ++$self->{_field_count} > $self->{max_fields};
            }
            return if $self->{_failed};
            $self->{_cur_is_file} = $is_file;
            $self->{_cur_bytes}   = 0;
            push @{$self->{_queue}}, ['part', $meta];
        },
        on_body => sub {
            my ($chunk, $final) = @_;
            return if $self->{_failed};
            $self->{_cur_bytes} += length $chunk;
            my $max = $self->{_cur_is_file} ? $self->{max_file_size} : $self->{max_field_size};
            if ($self->{_cur_bytes} > $max) {
                $self->{_failed} = ($self->{_cur_is_file} ? 'File' : 'Field')
                    . " part too large (max $max bytes)";
                return;                                  # stop enqueuing — bounds the queue
            }
            push @{$self->{_queue}}, ['body', $chunk];
        },
        on_error => sub { $self->{_failed} //= "Multipart parse error: $_[0]" },
    );
}

# Feed exactly one network message. Returns true if it fed data, false at exhaustion.
async sub _pump {
    my ($self) = @_;
    return 0 if $self->{_exhausted};
    my $msg = await $self->{receive}->();
    if (!$msg || !$msg->{type} || $msg->{type} eq 'http.disconnect') {
        $self->{_disconnect} = 1 if $msg && ($msg->{type} // '') eq 'http.disconnect';
        $self->{_exhausted}  = 1;
        $self->{_parser}->finish unless $self->{_disconnect};
        return 0;
    }
    if (defined $msg->{body} && length $msg->{body}) {
        $self->{_bytes_total} += length $msg->{body};
        if ($self->{_bytes_total} > $self->{max_request_body}) {
            $self->{_failed} = "Request body exceeded max_request_body ($self->{max_request_body} bytes)";
            $self->{_exhausted} = 1;
            return 0;
        }
        $self->{_parser}->parse($msg->{body});           # fires callbacks (enqueue + bookkeep)
    }
    unless ($msg->{more}) { $self->{_exhausted} = 1; $self->{_parser}->finish; }
    return 1;
}

=head1 METHODS

=head2 next

    my $part = await $stream->next;

Returns a Future resolving to the next L<PAGI::Request::Part>, or undef when
the stream is exhausted. Advancing past an unconsumed part auto-drains it.

=cut

async sub next {
    my ($self) = @_;
    croak $self->{_failed} if $self->{_failed};
    if ($self->{_current} && !$self->{_current}{_done}) { await $self->{_current}->skip; }  # auto-drain
    while (1) {
        croak $self->{_failed} if $self->{_failed};
        shift @{$self->{_queue}} while @{$self->{_queue}} && $self->{_queue}[0][0] eq 'body';  # defensive
        if (@{$self->{_queue}} && $self->{_queue}[0][0] eq 'part') {
            my (undef, $meta) = @{ shift @{$self->{_queue}} };
            $self->{_current} = PAGI::Request::Part->new(stream => $self, meta => $meta);
            return $self->{_current};
        }
        last unless await $self->_pump;
    }
    croak $self->{_failed} if $self->{_failed};
    croak "Client disconnected mid-stream" if $self->{_disconnect};
    return undef;
}

# Next body chunk for the current part: the chunk, or undef when the part ends.
async sub _next_chunk {
    my ($self) = @_;
    while (1) {
        croak $self->{_failed} if $self->{_failed};
        if (@{$self->{_queue}}) {
            my $kind = $self->{_queue}[0][0];
            if ($kind eq 'body') { my $ev = shift @{$self->{_queue}}; return $ev->[1]; }
            return undef if $kind eq 'part';             # next part began -> current done
        }
        if (!(await $self->_pump)) {
            croak $self->{_failed} if $self->{_failed};
            croak "Client disconnected mid-stream" if $self->{_disconnect};
            return undef;                                # clean EOF
        }
    }
}

package PAGI::Request::Part;
use strict;
use warnings;

use Future::AsyncAwait;

=head1 NAME

PAGI::Request::Part - A single part of a streaming multipart request

=head1 DESCRIPTION

Value object representing one part yielded by L<PAGI::Request::MultipartStream>.

=head1 CONSTRUCTOR

=head2 new

    my $part = PAGI::Request::Part->new(stream => $stream, meta => \%meta);

Constructs a part bound to its owning stream.

=head1 METHODS

=head2 name

The part's form field name from Content-Disposition.

=head2 filename

The part's filename from Content-Disposition, or undef for non-file parts.

=head2 content_type

The part's Content-Type header.

=head2 encoding

The part's Content-Transfer-Encoding header, or undef.

=head2 headers

A lc-keyed hashref of all the part's headers.

=head2 is_file

True if the part has a filename (i.e. is a file upload).

=head2 type

Returns 'file' for file parts, 'field' otherwise.

=head2 skip

    await $part->skip;

Drains and discards any remaining body of this part.

=cut

sub new { my ($c,%a)=@_; bless { stream=>$a{stream}, meta=>$a{meta}, _done=>0 }, $c }
sub name         { $_[0]{meta}{name} }
sub filename     { $_[0]{meta}{filename} }
sub content_type { $_[0]{meta}{content_type} }
sub encoding     { $_[0]{meta}{encoding} }
sub headers      { $_[0]{meta}{headers} }
sub is_file      { defined $_[0]{meta}{filename} ? 1 : 0 }
sub type         { $_[0]->is_file ? 'file' : 'field' }
async sub skip   { my $s=shift; 1 while defined(await $s->{stream}->_next_chunk); $s->{_done}=1; return; }

1;
