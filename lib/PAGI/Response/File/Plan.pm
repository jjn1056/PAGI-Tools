package PAGI::Response::File::Plan;

use strict;
use warnings;

use Carp qw(croak);
use Digest::MD5 qw(md5_hex);
use Fcntl qw(S_ISREG);

=encoding UTF-8

=head1 NAME

PAGI::Response::File::Plan - private selected-file response preflight value

=head1 DESCRIPTION

This internal immutable value performs request-time metadata, conditional,
logical-window, and strict single-range planning for
L<PAGI::Response::File> and L<PAGI::App::File>. It receives only an already
selected trusted filesystem path and never interprets a request URL path.

=cut

my %MIME_TYPES = (
    html => 'text/html',
    htm  => 'text/html',
    css  => 'text/css',
    js   => 'application/javascript',
    json => 'application/json',
    xml  => 'application/xml',
    txt  => 'text/plain',
    csv  => 'text/csv',
    pl   => 'text/plain',
    md   => 'text/plain',
    png  => 'image/png',
    jpg  => 'image/jpeg',
    jpeg => 'image/jpeg',
    gif  => 'image/gif',
    svg  => 'image/svg+xml',
    ico  => 'image/x-icon',
    webp => 'image/webp',
    woff => 'font/woff',
    woff2=> 'font/woff2',
    ttf  => 'font/ttf',
    otf  => 'font/otf',
    eot  => 'application/vnd.ms-fontobject',
    pdf  => 'application/pdf',
    zip  => 'application/zip',
    gz   => 'application/gzip',
    tar  => 'application/x-tar',
    mp3  => 'audio/mpeg',
    mp4  => 'video/mp4',
    webm => 'video/webm',
    ogg  => 'audio/ogg',
    wav  => 'audio/wav',
);

my %KNOWN_ARGS = map { $_ => 1 }
    qw(path scope offset length handle_ranges etag);

sub new {
    my ($class, @pairs) = @_;
    croak 'File plan arguments must be name/value pairs' if @pairs % 2;

    my %args;
    while (@pairs) {
        my ($name, $value) = splice @pairs, 0, 2;
        croak 'File plan argument names must be scalar strings'
            unless defined($name) && !ref($name) && length($name);
        croak "Unknown File plan argument '$name'" unless $KNOWN_ARGS{$name};
        croak "Duplicate File plan argument '$name'" if exists $args{$name};
        $args{$name} = $value;
    }

    my $path = $args{path};
    croak 'File plan path must be a defined nonempty scalar string'
        unless defined($path) && !ref($path) && length($path);
    my $scope = $args{scope};
    croak 'File plan scope must be an HTTP hashref'
        unless ref($scope) eq 'HASH'
            && defined($scope->{type}) && !ref($scope->{type})
            && $scope->{type} eq 'http';

    my @stat = stat($path);
    croak "Cannot inspect selected file '$path': $!" unless @stat;
    croak "Selected file '$path' must be a regular readable selected file"
        unless S_ISREG($stat[2]) && -r _;

    my $size = $stat[7];
    my $has_offset = exists $args{offset};
    my $has_length = exists $args{length};
    my $offset = $has_offset ? $args{offset} : 0;
    _nonnegative_integer('File plan offset', $offset);
    croak "File plan offset $offset exceeds file size $size"
        if $offset > $size;

    my $length = $has_length ? $args{length} : $size - $offset;
    _nonnegative_integer('File plan length', $length);
    croak "File plan window offset $offset length $length exceeds file size $size"
        if $length > $size - $offset;

    my $handle_ranges = exists($args{handle_ranges})
        ? $args{handle_ranges} : 1;
    croak 'File plan handle_ranges must be a boolean'
        unless defined($handle_ranges) && !ref($handle_ranges)
            && ($handle_ranges eq '0' || $handle_ranges eq '1');
    $handle_ranges = $handle_ranges ? 1 : 0;

    my $etag_policy = exists($args{etag}) ? $args{etag} : 'auto';
    croak 'File plan ETag policy must be automatic, disabled, or an entity-tag'
        if ref($etag_policy);
    my $etag;
    if (defined($etag_policy)) {
        if ($etag_policy eq 'auto') {
            $etag = '"' . md5_hex(join '-',
                @stat[0, 1, 2, 7, 9], $offset, $length,
            ) . '"';
        } else {
            croak 'File plan explicit ETag must be a valid entity-tag'
                unless _valid_entity_tag($etag_policy);
            $etag = $etag_policy;
        }
    }

    my $self = bless {
        _path              => $path,
        _file_size         => $size,
        _window_offset     => 0 + $offset,
        _window_length     => 0 + $length,
        _window_configured => $has_offset || $has_length ? 1 : 0,
        _etag              => $etag,
    }, $class;

    my $if_none_match = _first_header($scope, 'if-none-match');
    if (defined($etag) && $if_none_match && $if_none_match eq $etag) {
        $self->{_status} = 304;
        $self->{_headers} = [['etag', $etag]];
        $self->{_body_event} = {
            type => 'http.response.body', body => '', more => 0,
        };
        return $self;
    }

    my $content_type = $class->_content_type_for(
        $path, 'application/octet-stream',
    );
    my @base_headers = (
        ['content-type', $content_type],
        ['accept-ranges', 'bytes'],
    );
    push @base_headers, ['etag', $etag] if defined $etag;

    my $range;
    my $method = $scope->{method};
    if ($handle_ranges
            && defined($method) && !ref($method) && $method eq 'GET') {
        my @values = _header_values($scope, 'range');
        $range = join ',', map {
            defined($_) && !ref($_) ? $_ : ''
        } @values if @values;
    }
    my $parsed = _single_byte_range($range, $length);
    if (defined($parsed) && $parsed->{invalid}) {
        $self->{_status} = 416;
        $self->{_headers} = [['content-range', "bytes */$length"]];
        $self->{_body_event} = {
            type => 'http.response.body', body => '', more => 0,
        };
        return $self;
    }

    if (defined $parsed) {
        my $physical_offset = $offset + $parsed->{start};
        $self->{_status} = 206;
        $self->{_headers} = [
            $base_headers[0],
            ['content-length', $parsed->{length}],
            ['content-range',
                "bytes $parsed->{start}-$parsed->{end}/$length"],
            @base_headers[1 .. $#base_headers],
        ];
        $self->{_body_event} = {
            type   => 'http.response.body',
            file   => $path,
            offset => 0 + $physical_offset,
            length => 0 + $parsed->{length},
        };
        return $self;
    }

    $self->{_status} = 200;
    $self->{_headers} = [
        $base_headers[0],
        ['content-length', 0 + $length],
        @base_headers[1 .. $#base_headers],
    ];
    my %body_event = (
        type => 'http.response.body', file => $path,
    );
    if ($self->{_window_configured}) {
        $body_event{offset} = 0 + $offset;
        $body_event{length} = 0 + $length;
    }
    $self->{_body_event} = \%body_event;
    return $self;
}

sub _content_type_for {
    my ($class, $path, $default) = @_;
    my ($extension) = $path =~ /\.([^.]+)\z/;
    return $MIME_TYPES{lc($extension // '')} // $default;
}

sub _nonnegative_integer {
    my ($label, $value) = @_;
    croak "$label must be a nonnegative integer"
        unless defined($value) && !ref($value) && $value =~ /\A[0-9]+\z/;
    return;
}

sub _valid_entity_tag {
    my ($value) = @_;
    return 0 unless defined($value) && !ref($value) && !utf8::is_utf8($value);
    return $value =~ /\A(?:W\/)?"[\x21\x23-\x7e\x80-\xff]*"\z/ ? 1 : 0;
}

sub _header_values {
    my ($scope, $name) = @_;
    $name = lc $name;
    my @values;
    for my $header (@{$scope->{headers} // []}) {
        next unless ref($header) eq 'ARRAY' && @$header >= 2;
        my $field = $header->[0];
        next unless defined($field) && !ref($field);
        push @values, $header->[1] if lc($field) eq $name;
    }
    return @values;
}

sub _first_header {
    my ($scope, $name) = @_;
    my @values = _header_values($scope, $name);
    return @values ? $values[0] : undef;
}

sub _single_byte_range {
    my ($range, $size) = @_;
    return undef unless defined $range;
    return { invalid => 1 }
        unless $range =~ /\Abytes=([0-9]*)-([0-9]*)\z/;

    my ($start_text, $end_text) = ($1, $2);
    return { invalid => 1 }
        if $start_text eq '' && $end_text eq '';

    my ($start, $end);
    if ($start_text eq '') {
        my $suffix_length = 0 + $end_text;
        return { invalid => 1 } if $suffix_length == 0 || $size == 0;
        $suffix_length = $size if $suffix_length > $size;
        $start = $size - $suffix_length;
        $end = $size - 1;
    } else {
        $start = 0 + $start_text;
        return { invalid => 1 } if $start >= $size;

        if ($end_text eq '') {
            $end = $size - 1;
        } else {
            $end = 0 + $end_text;
            return { invalid => 1 } if $start > $end;
            $end = $size - 1 if $end >= $size;
        }
    }

    return {
        start  => $start,
        end    => $end,
        length => $end - $start + 1,
    };
}

sub status {
    croak 'File plan status is read-only' if @_ != 1;
    return $_[0]->{_status};
}

sub headers {
    croak 'File plan headers are read-only' if @_ != 1;
    return [map { [@$_] } @{$_[0]->{_headers}}];
}

sub body_event {
    croak 'File plan body_event is read-only' if @_ != 1;
    return {%{$_[0]->{_body_event}}};
}

sub _logical_length {
    croak 'File plan logical length is read-only' if @_ != 1;
    return $_[0]->{_window_length};
}

1;
