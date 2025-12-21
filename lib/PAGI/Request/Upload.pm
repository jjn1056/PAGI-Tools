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

    my $upload = await $req->upload('avatar');

    if ($upload && !$upload->is_empty) {
        my $filename = $upload->filename;
        my $size = $upload->size;
        my $content = $upload->slurp;

        await $upload->save_to('/path/to/save');
    }

=head1 DESCRIPTION

PAGI::Request::Upload represents an uploaded file from a multipart form.
Files may be stored in memory (small files) or spooled to a temporary
file (large files).

=head1 CONSTRUCTOR

=head2 new

    my $upload = PAGI::Request::Upload->new(
        field_name   => 'avatar',
        filename     => 'photo.jpg',
        content_type => 'image/jpeg',
        data         => $bytes,        # OR
        temp_path    => '/tmp/abc123', # for spooled files
        size         => 12345,
    );

=head1 PROPERTIES

=head2 field_name

Form field name.

=head2 filename

Original filename from the upload.

=head2 basename

Filename without path components (safe for filesystem use).

=head2 content_type

MIME type of the uploaded file.

=head2 size

File size in bytes.

=head2 temp_path

Path to temporary file (if spooled to disk).

=head1 PREDICATES

=head2 is_empty

True if no data was uploaded.

=head2 is_in_memory

True if file data is stored in memory.

=head2 is_on_disk

True if file data is spooled to a temp file.

=head1 CONTENT METHODS

=head2 slurp

    my $bytes = $upload->slurp;

Read entire file content into memory.

=head2 fh

    my $fh = $upload->fh;

Get a filehandle for reading the upload.

=head1 ASYNC METHODS

=head2 copy_to

    await $upload->copy_to('/path/to/destination');

Copy the uploaded file to a destination.

=head2 move_to

    await $upload->move_to('/path/to/destination');

Move the uploaded file to a destination (more efficient for disk files).

=head2 save_to

Alias for C<copy_to>.

=head1 CLEANUP

Temporary files are automatically deleted when the Upload object is
destroyed. If you want to keep the file, use C<move_to> or C<copy_to>.

=head1 SEE ALSO

L<PAGI::Request>

=cut
