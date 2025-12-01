package PAGI::App::Directory;

use strict;
use warnings;
use experimental 'signatures';
use Future::AsyncAwait;
use parent 'PAGI::App::File';
use JSON::PP ();

=head1 NAME

PAGI::App::Directory - Serve files with directory listing

=head1 SYNOPSIS

    use PAGI::App::Directory;

    my $app = PAGI::App::Directory->new(
        root => '/var/www/files',
    )->to_app;

=cut

sub new ($class, %args) {
    my $self = $class->SUPER::new(%args);
    $self->{show_hidden} = $args{show_hidden} // 0;
    return $self;
}

sub to_app ($self) {
    my $parent_app = $self->SUPER::to_app();
    my $root = $self->{root};

    return async sub ($scope, $receive, $send) {
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

        my $path = $scope->{path} // '/';
        $path =~ s{^/+}{};
        my $dir_path = "$root/$path";

        # If it's a directory without index file, show listing
        if (-d $dir_path) {
            my $has_index = 0;
            for my $index (@{$self->{index}}) {
                if (-f "$dir_path/$index") {
                    $has_index = 1;
                    last;
                }
            }

            unless ($has_index) {
                await $self->_send_listing($send, $scope, $dir_path, $path);
                return;
            }
        }

        # Fall back to parent file serving
        await $parent_app->($scope, $receive, $send);
    };
}

async sub _send_listing ($self, $send, $scope, $dir_path, $rel_path) {
    opendir my $dh, $dir_path or do {
        await $self->_send_error($send, 403, 'Forbidden');
        return;
    };

    my @entries;
    while (my $entry = readdir $dh) {
        next if $entry eq '.';
        next if !$self->{show_hidden} && $entry =~ /^\./;

        my $full_path = "$dir_path/$entry";
        my @stat = stat($full_path);
        push @entries, {
            name  => $entry,
            is_dir => -d $full_path ? 1 : 0,
            size  => $stat[7] // 0,
            mtime => $stat[9] // 0,
        };
    }
    closedir $dh;

    # Sort directories first, then by name
    @entries = sort { $b->{is_dir} <=> $a->{is_dir} || $a->{name} cmp $b->{name} } @entries;

    # Check Accept header for JSON
    my $accept = $self->_get_header($scope, 'accept') // '';
    if ($accept =~ m{application/json}) {
        my $json = JSON::PP::encode_json(\@entries);
        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'application/json'], ['content-length', length($json)]],
        });
        await $send->({ type => 'http.response.body', body => $json, more => 0 });
        return;
    }

    # HTML listing
    my $base_path = $rel_path eq '' ? '/' : "/$rel_path";
    $base_path =~ s{/+$}{};

    my $html = "<!DOCTYPE html><html><head><title>Index of $base_path/</title>";
    $html .= '<style>body{font-family:sans-serif;margin:20px}table{border-collapse:collapse}';
    $html .= 'th,td{padding:8px 16px;text-align:left;border-bottom:1px solid #ddd}';
    $html .= 'a{text-decoration:none;color:#0066cc}a:hover{text-decoration:underline}</style></head>';
    $html .= "<body><h1>Index of $base_path/</h1><table><tr><th>Name</th><th>Size</th></tr>";

    if ($rel_path ne '') {
        $html .= '<tr><td><a href="../">..</a></td><td>-</td></tr>';
    }

    for my $entry (@entries) {
        my $name = $entry->{name};
        my $display = $entry->{is_dir} ? "$name/" : $name;
        my $href = "$name" . ($entry->{is_dir} ? '/' : '');
        my $size = $entry->{is_dir} ? '-' : _format_size($entry->{size});
        $html .= qq{<tr><td><a href="$href">$display</a></td><td>$size</td></tr>};
    }

    $html .= '</table></body></html>';

    await $send->({
        type => 'http.response.start',
        status => 200,
        headers => [['content-type', 'text/html'], ['content-length', length($html)]],
    });
    await $send->({ type => 'http.response.body', body => $html, more => 0 });
}

sub _format_size {
    my $size = shift;
    return '0' if $size == 0;
    my @units = qw(B KB MB GB);
    my $i = 0;
    while ($size >= 1024 && $i < $#units) {
        $size /= 1024;
        $i++;
    }
    return sprintf("%.1f %s", $size, $units[$i]);
}

1;
