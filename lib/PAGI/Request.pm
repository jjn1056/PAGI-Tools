package PAGI::Request;
use strict;
use warnings;
use Hash::MultiValue;
use URI::Escape qw(uri_unescape);
use Encode qw(decode_utf8);

sub new {
    my ($class, $scope, $receive) = @_;
    return bless {
        scope   => $scope,
        receive => $receive,
        _body_read => 0,
    }, $class;
}

# Basic properties from scope
sub method       { shift->{scope}{method} }
sub path         { shift->{scope}{path} }
sub raw_path     { my $s = shift; $s->{scope}{raw_path} // $s->{scope}{path} }
sub query_string { shift->{scope}{query_string} // '' }
sub scheme       { shift->{scope}{scheme} // 'http' }
sub http_version { shift->{scope}{http_version} // '1.1' }
sub client       { shift->{scope}{client} }
sub raw          { shift->{scope} }

# Host from headers
sub host {
    my $self = shift;
    return $self->header('host');
}

# Content-Type shortcut
sub content_type {
    my $self = shift;
    my $ct = $self->header('content-type') // '';
    # Strip parameters like charset
    $ct =~ s/;.*//;
    return $ct;
}

# Content-Length shortcut
sub content_length {
    my $self = shift;
    return $self->header('content-length');
}

# Single header lookup (case-insensitive, returns last value)
sub header {
    my ($self, $name) = @_;
    $name = lc($name);
    my $value;
    for my $pair (@{$self->{scope}{headers} // []}) {
        if (lc($pair->[0]) eq $name) {
            $value = $pair->[1];
        }
    }
    return $value;
}

# All headers as Hash::MultiValue (cached, case-insensitive keys)
sub headers {
    my $self = shift;
    return $self->{_headers} if $self->{_headers};

    my @pairs;
    for my $pair (@{$self->{scope}{headers} // []}) {
        push @pairs, lc($pair->[0]), $pair->[1];
    }

    $self->{_headers} = Hash::MultiValue->new(@pairs);
    return $self->{_headers};
}

# All values for a header
sub header_all {
    my ($self, $name) = @_;
    return $self->headers->get_all(lc($name));
}

# Query params as Hash::MultiValue (cached)
sub query_params {
    my $self = shift;
    return $self->{_query_params} if $self->{_query_params};

    my $qs = $self->query_string;
    my @pairs;

    for my $part (split /&/, $qs) {
        next unless length $part;
        my ($key, $val) = split /=/, $part, 2;
        $key //= '';
        $val //= '';

        # Decode percent-encoding and UTF-8
        $key = decode_utf8(uri_unescape($key));
        $val = decode_utf8(uri_unescape($val));

        push @pairs, $key, $val;
    }

    $self->{_query_params} = Hash::MultiValue->new(@pairs);
    return $self->{_query_params};
}

# Shortcut for single query param
sub query {
    my ($self, $name) = @_;
    return $self->query_params->get($name);
}

# Method predicates
sub is_get     { uc(shift->method // '') eq 'GET' }
sub is_post    { uc(shift->method // '') eq 'POST' }
sub is_put     { uc(shift->method // '') eq 'PUT' }
sub is_patch   { uc(shift->method // '') eq 'PATCH' }
sub is_delete  { uc(shift->method // '') eq 'DELETE' }
sub is_head    { uc(shift->method // '') eq 'HEAD' }
sub is_options { uc(shift->method // '') eq 'OPTIONS' }

1;

__END__

=head1 NAME

PAGI::Request - Convenience wrapper for PAGI request scope

=head1 SYNOPSIS

    use PAGI::Request;

    async sub app {
        my ($scope, $receive, $send) = @_;
        my $req = PAGI::Request->new($scope, $receive);

        my $method = $req->method;
        my $path = $req->path;
        my $ct = $req->content_type;
    }

=cut
