package PAGI::Utils::TextDecoder;

use strict;
use warnings;
use Carp qw(croak);
use Encode qw(find_encoding FB_CROAK FB_DEFAULT STOP_AT_PARTIAL);

sub new {
    my ($class, $name, %opts) = @_;
    my $strict = delete $opts{strict};
    my $strip_bom = delete $opts{strip_bom};
    croak 'PAGI::Utils::TextDecoder: unknown option ' . join(', ', map { "'$_'" } sort keys %opts)
        if %opts;
    croak 'PAGI::Utils::TextDecoder: expects an encoding name' unless defined $name;
    my $encoding = find_encoding($name)
        or croak "PAGI::Utils::TextDecoder: unknown encoding '$name'";
    # Encode decodes escape-based encodings (ISO-2022-*, UTF-7) only line by line.
    croak "PAGI::Utils::TextDecoder: '$name' cannot be decoded in chunks; decode the whole input"
        if $encoding->needs_lines;
    # Encode's 'utf8' is its lax variant; UTF-8 is decoded strictly however
    # it is spelt, as $request->text does.
    $encoding = find_encoding('UTF-8') if $encoding->name =~ /\Autf-?8/i;
    # Plain UTF-16 and UTF-32 consume a leading BOM themselves to choose the
    # byte order, so strip_bom has nothing left to drop: a U+FEFF after that
    # mark is text.
    $strip_bom = 0 if $encoding->name =~ /\AUTF-(?:16|32)\z/i;
    # Encode's UTF-16/32 decoder treats a chunk boundary inside a code unit,
    # or after the first half of a surrogate pair, as an error under FB_CROAK
    # (Unicode.xs checks it before STOP_AT_PARTIAL), so strict decoding never
    # hands it one: whole units only, and in UTF-16 a trailing high surrogate
    # waits for its other half. Its byte order comes from the name, or for
    # plain UTF-16 from the BOM, big-endian without one (RFC 2781, as Encode).
    my ($unit, $order) = (0, undef);
    if ($strict && $encoding->isa('Encode::Unicode')) {
        $unit  = $encoding->name =~ /32/ ? 4 : 2;
        $order = $encoding->name =~ /\AUTF-16LE\z/i ? 'v'
               : $encoding->name =~ /\AUTF-16BE\z/i ? 'n'
               : $encoding->name =~ /\AUTF-16\z/i   ? ''    # from the BOM, below
               : undef;
    }
    return bless {
        name     => $name,
        decoder  => $encoding->renew,    # one stateful decoder: a BOM's byte order, a held tail
        check    => ($strict ? FB_CROAK : FB_DEFAULT) | STOP_AT_PARTIAL,
        strict   => $strict ? 1 : 0,
        strip_bom => $strip_bom ? 1 : 0,
        unit     => $unit,
        order    => $order,
        held     => '',
        finished => 0,
    }, $class;
}

sub decode {
    my ($self, $bytes) = @_;
    croak 'PAGI::Utils::TextDecoder: already finished' if $self->{finished};
    $bytes = '' unless defined $bytes;
    croak 'PAGI::Utils::TextDecoder: expects bytes' if $bytes =~ /[^\x00-\xFF]/;
    my $data = $self->{held} . $bytes;
    my $wait = '';
    if (my $unit = $self->{unit}) {
        my $keep = length($data) % $unit;
        if (defined $self->{order} && length($data) - $keep >= 2) {
            # Nothing has been decoded before the first two bytes arrive, so
            # $data still starts with the stream's first bytes here.
            $self->{order} = substr($data, 0, 2) eq "\xFF\xFE" ? 'v' : 'n'
                if $self->{order} eq '';
            my $last = unpack $self->{order}, substr($data, length($data) - $keep - 2, 2);
            $keep += 2 if $last >= 0xD800 && $last <= 0xDBFF;
        }
        $wait = substr($data, length($data) - $keep, $keep, '');
    }
    my $text;
    eval { $text = $self->{decoder}->decode($data, $self->{check}); 1 }
        or $self->_fail($@);
    $self->{held} = $data . $wait;    # an unfinished character, and any unit held back
    return $self->_strip_bom($text);
}

sub finish {
    my ($self) = @_;
    croak 'PAGI::Utils::TextDecoder: already finished' if $self->{finished};
    $self->{finished} = 1;
    my $held = $self->{held};
    $self->{held} = '';
    return '' unless length $held;
    # A renewed decoder never reports a cut-off final character itself, even
    # under FB_CROAK, so the held bytes are judged here.
    if ($self->{unit}) {
        # Strict UTF-16/32: the units held back are decoded now; a lone lead
        # surrogate or an odd final byte dies here.
        my $text;
        eval { $text = $self->{decoder}->decode($held, FB_CROAK); 1 }
            or $self->_fail($@);
        $self->_fail('the input ends inside a character') if length $held;
        return $self->_strip_bom($text);
    }
    $self->_fail('the input ends inside a character') if $self->{strict};
    return "\x{FFFD}";
}

# A byte-order mark is dropped once, from the first text decoded: the first
# call may complete no character yet (a BOM split across chunks).
sub _strip_bom {
    my ($self, $text) = @_;
    if ($self->{strip_bom} && length $text) {
        $text =~ s/\A\x{FEFF}//;
        $self->{strip_bom} = 0;
    }
    return $text;
}

sub _fail {
    my ($self, $cause) = @_;
    $self->{finished} = 1;
    $cause =~ s/ at .+? line \d+\.?\n?\z//;
    chomp $cause;
    die "PAGI::Utils::TextDecoder: not valid $self->{name}: $cause\n";
}

1;

__END__

=head1 NAME

PAGI::Utils::TextDecoder - decode a byte stream to text as it arrives

=head1 SYNOPSIS

    use PAGI::Utils::TextDecoder;

    my $decoder = PAGI::Utils::TextDecoder->new('Shift_JIS', strict => 1);
    while (defined(my $bytes = await $source->next_chunk)) {
        handle($decoder->decode($bytes));    # whole characters only
    }
    # Only when the input really ended here, not when the sender went away.
    handle($decoder->finish) unless $source->truncated;

=head1 DESCRIPTION

Bytes arrive in chunks that can split a character anywhere. This decoder
turns each chunk into the text it completes and holds back an unfinished
character for the next one. It wraps Encode's stateful decoder (a renewed
encoding object with C<STOP_AT_PARTIAL>, as PerlIO's C<:encoding> layer
does), so a byte-order mark sets the byte order for the whole stream.

L<PAGI::Request/body_stream> is built on it (its C<decode> and C<strict>
options). Use it directly for any other byte source: a multipart part, a
WebSocket upload, a pipe. It knows nothing about HTTP.

=head1 CONSTRUCTOR

=head2 new

    my $decoder = PAGI::Utils::TextDecoder->new($encoding, strict => 1, strip_bom => 1);

C<$encoding> is any name L<Encode> knows. UTF-8 is decoded strictly however
it is spelt (C<utf8>, C<UTF-8>), as L<PAGI::Request/text> does: Encode's
C<utf8> is its lax variant.

C<strict> decides what happens to bytes that are not valid in the encoding:
off (the default) replaces them with U+FFFD; on makes C<decode> or C<finish>
die. Use strict where you store or act on the text; leave it off where a
garbled character does no harm.

C<strip_bom> drops a single byte-order mark (U+FEFF) at the very start of
the text. Off by default: in UTF-8, and in UTF-16LE/BE named as such, the
mark is text. Plain C<UTF-16> and C<UTF-32> consume it to choose the byte
order, so there the option does nothing: a U+FEFF after that mark is text
and is kept. Python calls this decoding
C<utf-8-sig>.

Dies at once for an option other than C<strict> and C<strip_bom>, for an encoding Encode does
not know, and for one Encode decodes only line by line (ISO-2022-JP and -KR,
UTF-7, HZ): decode those whole, or line by line with PerlIO's C<:encoding>.

=head1 METHODS

=head2 decode

    my $text = $decoder->decode($bytes);

Returns the text these bytes complete, possibly C<''>. An unfinished
character is held for the next call. Without strict, invalid bytes become
U+FFFD; with strict, the call that carries them dies. Dies with C<expects
bytes> when given characters above 0xFF -- a caller's mistake, not invalid
input.

=head2 finish

    my $rest = $decoder->finish;

Call it once, when the input really ended. Returns C<''>, or U+FFFD for a
character the bytes ended inside; with strict, that dies instead. A renewed
Encode decoder never reports a cut-off final character itself, which is why
this method exists.

Do not call it when a client disconnected: the bytes stopped, they were not
wrong. Drop the decoder and report the disconnect instead, as
L<PAGI::Request::BodyStream> does with C<truncated>.

A decoder is one-shot: after C<finish>, or after it has died, C<decode> and
C<finish> die with C<already finished>.

=head1 ERRORS

Invalid input dies with a plain string ending in a newline:

    PAGI::Utils::TextDecoder: not valid UTF-8: UTF-8 "\xFF" does not map to Unicode
    PAGI::Utils::TextDecoder: not valid UTF-8: the input ends inside a character

The owner of the protocol turns it into its own answer:
L<PAGI::Request::BodyStream> throws a L<PAGI::Exception::RequestBody> 400; a
WebSocket handler would close with 1007 (invalid frame payload data).

=head1 LIMITS

A byte-order mark is consumed only by the encodings whose byte order it
decides, plain C<UTF-16> and C<UTF-32>. With C<UTF-8>, C<UTF-16LE>/C<BE> and
C<UTF-32LE>/C<BE> it is text and arrives as U+FEFF, as in Encode and
L<PAGI::Request/text>; C<s/\A\x{FEFF}//> on the first chunk removes it, and
is harmless when there is none.

Strict UTF-16/32 holds back an incomplete code unit, and in UTF-16 the
first half of a surrogate pair, until the rest arrives: Encode's UTF-16/32
decoder reports such a boundary as an error, so the decoder never hands it
one.

=head1 SEE ALSO

L<PAGI::Request::BodyStream>, L<PAGI::Request/body_stream>, L<Encode>,
L<PerlIO::encoding>

=cut
