package PAGI::Request::Upload;
use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';

use Future::AsyncAwait;
use IO::Async::Loop;
use PAGI::Util::AsyncFile;
use File::Basename qw(fileparse);
use File::Copy qw(copy move);
use File::Spec;
use Carp qw(croak);

our $VERSION = '0.01';

# Constructor
sub new ($class, %args) {
    my $self = bless {
        field_name   => $args{field_name}   // croak("field_name is required"),
        filename     => $args{filename}     // '',
        content_type => $args{content_type} // 'application/octet-stream',
        data         => $args{data},        # in-memory content
        temp_path    => $args{temp_path},   # on-disk path
        size         => $args{size},
        _cleaned_up  => 0,
    }, $class;

    # Calculate size if not provided
    if (!defined $self->{size}) {
        if (defined $self->{data}) {
            $self->{size} = length($self->{data});
        } elsif (defined $self->{temp_path} && -f $self->{temp_path}) {
            $self->{size} = -s $self->{temp_path};
        } else {
            $self->{size} = 0;
        }
    }

    return $self;
}

# Accessors
sub field_name ($self)   { $self->{field_name} }
sub filename ($self)     { $self->{filename} }
sub content_type ($self) { $self->{content_type} }
sub size ($self)         { $self->{size} }
sub temp_path ($self)    { $self->{temp_path} }

# Basename - strips Windows and Unix paths
sub basename ($self) {
    my $filename = $self->{filename};
    return '' unless $filename;

    # Strip Windows paths (C:\Users\... or \\server\share\...)
    $filename =~ s/.*[\\\/]//;

    return $filename;
}

# Predicates
sub is_empty ($self) {
    return $self->{size} == 0;
}

sub is_in_memory ($self) {
    return defined($self->{data});
}

sub is_on_disk ($self) {
    return defined($self->{temp_path});
}

# Content access - slurp
sub slurp ($self) {
    if ($self->is_in_memory) {
        return $self->{data};
    } elsif ($self->is_on_disk) {
        open my $fh, '<:raw', $self->{temp_path}
            or croak("Cannot read $self->{temp_path}: $!");
        my $content = do { local $/; <$fh> };
        close $fh;
        return $content;
    }
    return '';
}

# Content access - filehandle
sub fh ($self) {
    if ($self->is_in_memory) {
        open my $fh, '<', \$self->{data}
            or croak("Cannot create filehandle from memory: $!");
        return $fh;
    } elsif ($self->is_on_disk) {
        open my $fh, '<:raw', $self->{temp_path}
            or croak("Cannot open $self->{temp_path}: $!");
        return $fh;
    }
    croak("No content available");
}

# Async copy
async sub copy_to ($self, $destination) {
    my $loop = IO::Async::Loop->new;

    # Ensure destination directory exists
    my ($name, $dir) = fileparse($destination);
    if (!-d $dir) {
        require File::Path;
        File::Path::make_path($dir);
    }

    if ($self->is_in_memory) {
        # Write data to destination
        await PAGI::Util::AsyncFile->write_file($loop, $destination, $self->{data});
        return;
    } elsif ($self->is_on_disk) {
        # Use File::Copy
        copy($self->{temp_path}, $destination)
            or croak("Cannot copy to $destination: $!");
        return;
    }

    croak("No content to copy");
}

# Async move
async sub move_to ($self, $destination) {
    my $loop = IO::Async::Loop->new;

    # Ensure destination directory exists
    my ($name, $dir) = fileparse($destination);
    if (!-d $dir) {
        require File::Path;
        File::Path::make_path($dir);
    }

    if ($self->is_in_memory) {
        # Write and clear memory
        await PAGI::Util::AsyncFile->write_file($loop, $destination, $self->{data});

        # Update to point to new location
        delete $self->{data};
        $self->{temp_path} = $destination;

        return;
    } elsif ($self->is_on_disk) {
        # Use File::Copy::move
        move($self->{temp_path}, $destination)
            or croak("Cannot move to $destination: $!");

        # Update path
        $self->{temp_path} = $destination;

        return;
    }

    croak("No content to move");
}

# Alias for move_to
async sub save_to ($self, $destination) {
    await $self->move_to($destination);
}

# Discard the upload
sub discard ($self) {
    return if $self->{_cleaned_up};

    if ($self->is_on_disk && -f $self->{temp_path}) {
        unlink $self->{temp_path};
    }

    delete $self->{data};
    delete $self->{temp_path};
    $self->{_cleaned_up} = 1;
}

# Destructor - cleanup temp files
sub DESTROY ($self) {
    $self->discard;
}

1;

__END__

=head1 NAME

PAGI::Request::Upload - Uploaded file representation

=head1 SYNOPSIS

    use PAGI::Request::Upload;

    # From memory (small files)
    my $upload = PAGI::Request::Upload->new(
        field_name   => 'avatar',
        filename     => 'photo.jpg',
        content_type => 'image/jpeg',
        data         => $image_data,
    );

    # From temp file (large files)
    my $upload = PAGI::Request::Upload->new(
        field_name   => 'document',
        filename     => 'report.pdf',
        content_type => 'application/pdf',
        temp_path    => '/tmp/upload_xyz123',
        size         => 1048576,
    );

    # Metadata
    say $upload->field_name;      # 'avatar'
    say $upload->filename;         # 'photo.jpg'
    say $upload->basename;         # 'photo.jpg' (strips paths)
    say $upload->content_type;     # 'image/jpeg'
    say $upload->size;             # 12345

    # Predicates
    say "empty" if $upload->is_empty;
    say "in memory" if $upload->is_in_memory;
    say "on disk" if $upload->is_on_disk;

    # Content access
    my $content = $upload->slurp;
    my $fh = $upload->fh;

    # Async persistence
    await $upload->copy_to('/path/to/destination.jpg');  # keeps original
    await $upload->move_to('/path/to/destination.jpg');  # removes original
    await $upload->save_to('/path/to/destination.jpg');  # alias for move_to

=head1 DESCRIPTION

PAGI::Request::Upload represents an uploaded file from a multipart/form-data
request. It can store the content either in memory (for small files) or in
a temporary file on disk (for large files).

The temp file is automatically cleaned up when the object is destroyed unless
it has been moved to a permanent location.

=head1 CONSTRUCTOR

=head2 new

    my $upload = PAGI::Request::Upload->new(
        field_name   => 'file',      # required - form field name
        filename     => 'photo.jpg', # optional - original filename
        content_type => 'image/jpeg',# optional - defaults to application/octet-stream
        data         => $bytes,      # for in-memory storage
        temp_path    => $path,       # for on-disk storage
        size         => $size,       # optional - auto-calculated if not provided
    );

Either C<data> or C<temp_path> should be provided, not both.

=head1 ACCESSORS

=head2 field_name

Returns the form field name.

=head2 filename

Returns the original filename from the upload.

=head2 basename

Returns just the filename portion, stripping any Windows or Unix path components.
For example, C<C:\Users\John\photo.jpg> becomes C<photo.jpg>.

=head2 content_type

Returns the MIME type of the upload.

=head2 size

Returns the size in bytes.

=head2 temp_path

Returns the path to the temporary file if stored on disk.

=head1 PREDICATES

=head2 is_empty

Returns true if the upload has zero size.

=head2 is_in_memory

Returns true if the upload is stored in memory.

=head2 is_on_disk

Returns true if the upload is stored in a temporary file.

=head1 CONTENT ACCESS

=head2 slurp

Returns the entire content as a string.

=head2 fh

Returns a filehandle for reading the content.

=head1 ASYNC METHODS

=head2 copy_to

    await $upload->copy_to($destination_path);

Copies the upload to the specified path. The original upload remains accessible.

=head2 move_to

    await $upload->move_to($destination_path);

Moves the upload to the specified path. The original temp file is removed.

=head2 save_to

Alias for C<move_to>.

=head1 OTHER METHODS

=head2 discard

    $upload->discard;

Manually discards the upload, cleaning up any temp files. Called automatically
on object destruction.

=head1 AUTHOR

PAGI Contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
