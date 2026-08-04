package PAGI::Authority;

use strict;
use warnings;
use Carp qw(croak);
use Socket qw(AF_INET6 inet_pton);

sub validate {
    my ($class, $value) = @_;

    _invalid() unless defined $value && !ref($value) && length($value);
    _invalid() if $value =~ /[^\x21-\x7e]/;

    my ($host, $port);
    if ($value =~ /\A\[([^\[\]]+)\](?::([0-9]+))?\z/) {
        ($host, $port) = ($1, $2);
        _invalid() unless $host !~ /%/ && inet_pton(AF_INET6, $host);
    } elsif ($value =~ /\A([^:]+)(?::([0-9]+))?\z/) {
        ($host, $port) = ($1, $2);
        _invalid() unless _valid_reg_name_or_ipv4($host);
    } else {
        _invalid();
    }

    _validate_port($port) if defined $port;
    return $value;
}

sub host_from_scope {
    my ($class, $scope) = @_;

    croak 'authority scope must be a hashref' unless ref($scope) eq 'HASH';
    my $pairs = exists $scope->{headers} ? $scope->{headers} : [];
    croak 'scope headers must be an arrayref of pairs'
        unless ref($pairs) eq 'ARRAY';

    my @host;
    for my $pair (@$pairs) {
        croak 'scope headers must be an arrayref of pairs'
            unless ref($pair) eq 'ARRAY' && @$pair == 2
                && defined $pair->[0] && !ref($pair->[0])
                && defined $pair->[1] && !ref($pair->[1]);
        my $name = $pair->[0];
        $name =~ tr/A-Z/a-z/;
        push @host, $pair->[1] if $name eq 'host';
    }

    croak 'Host header must occur at most once' if @host > 1;
    return undef unless @host;
    return $class->validate($host[0]);
}

sub from_scope {
    my ($class, $scope) = @_;

    my $host = $class->host_from_scope($scope);
    return $host if defined $host;

    my $scheme = defined $scope->{scheme} ? lc($scope->{scheme}) : 'http';
    return _format_server($scope->{server}, $scheme);
}

sub _format_server {
    my ($server, $scheme) = @_;

    _scope_server_invalid()
        unless ref($server) eq 'ARRAY' && (@$server == 1 || @$server == 2);

    my ($host, $port) = @$server;
    _scope_server_invalid() unless defined $host && !ref($host) && length($host);

    my $rendered_host;
    if ($host =~ /\A\[([^\[\]]+)\]\z/) {
        my $ipv6 = $1;
        _scope_server_invalid()
            unless $ipv6 !~ /[^\x21-\x7e]/ && $ipv6 !~ /%/
                && inet_pton(AF_INET6, $ipv6);
        $rendered_host = "[$ipv6]";
    } elsif ($host !~ /[^\x21-\x7e]/ && $host !~ /%/
        && inet_pton(AF_INET6, $host)) {
        $rendered_host = "[$host]";
    } else {
        _scope_server_invalid()
            unless $host !~ /[^\x21-\x7e]/ && _valid_reg_name_or_ipv4($host);
        $rendered_host = $host;
    }

    return $rendered_host if @$server == 1;

    _scope_server_invalid() unless _valid_port($port);
    return $rendered_host if _is_default_server_port($scheme, $port);
    return "$rendered_host:$port";
}

sub _valid_reg_name_or_ipv4 {
    my ($host) = @_;

    return unless defined $host && !ref($host) && length($host);

    my @labels = split /\./, $host, -1;
    pop @labels if $labels[-1] eq '';
    return unless @labels;
    return unless !grep { $_ !~ /\A[A-Za-z0-9_~-]+\z/ } @labels;

    return 1 unless $host =~ /\A[0-9.]+\z/;

    my @octets = split /\./, $host, -1;
    return unless @octets == 4;
    for my $octet (@octets) {
        return unless $octet =~ /\A(?:0|[1-9][0-9]{0,2})\z/;
        return unless $octet <= 255;
    }

    return 1;
}

sub _validate_port {
    my ($port) = @_;
    _invalid() unless _valid_port($port);
}

sub _valid_port {
    my ($port) = @_;
    return unless defined $port && !ref($port) && $port =~ /\A[0-9]+\z/;

    my $significant = $port;
    $significant =~ s/\A0+//;
    $significant = '0' unless length($significant);
    return unless length($significant) <= 5;
    return unless length($significant) < 5 || $significant le '65535';

    return 1;
}

sub _is_default_server_port {
    my ($scheme, $port) = @_;
    my $number = $port;
    $number =~ s/\A0+//;
    $number = '0' unless length($number);

    return 1 if ($scheme eq 'http' || $scheme eq 'ws') && $number eq '80';
    return 1 if ($scheme eq 'https' || $scheme eq 'wss') && $number eq '443';
    return;
}

sub _invalid {
    croak 'invalid authority';
}

sub _scope_server_invalid {
    croak 'scope server cannot provide an authority';
}

1;

=head1 NAME

PAGI::Authority - validate trusted authority values and derive them from a scope

=head1 SYNOPSIS

    my $authority = PAGI::Authority->validate('example.com:443');
    my $host      = PAGI::Authority->host_from_scope($scope);
    my $effective = PAGI::Authority->from_scope($scope);

=head1 DESCRIPTION

This module supplies a small, stateless boundary for authority values that are
safe to use after validation.  Its class methods do not cache or mutate their
arguments.

=head1 METHODS

=head2 validate

    my $authority = PAGI::Authority->validate($value);

Returns the exact input spelling when it is a valid authority.  Accepted values
are visible-ASCII registered names and canonical dotted-decimal IPv4 addresses,
each with an optional decimal port, or a bracketed IPv6 literal with an optional
decimal port.  Registered-name labels contain letters, digits, underscores,
hyphens, or tildes; one trailing dot is allowed.

Whitespace, control and non-ASCII characters, URI delimiters, empty labels,
non-canonical or abbreviated IPv4 forms, unbracketed IPv6, IPv6 zone IDs,
IPvFuture, and ports outside C<0> through C<65535> are rejected.  Failure croaks
with C<invalid authority> and never includes the supplied value.

=head2 host_from_scope

    my $host = PAGI::Authority->host_from_scope($scope);

Reads raw C<< $scope->{headers} >> as an array reference of two-element
name/value array references.  Field names are ASCII-case-folded.  Returns
C<undef> if Host is absent, otherwise validates and returns the only Host value.
Malformed header shapes and multiple Host pairs croak; duplicate Host fields are
not treated as a last-value lookup.

=head2 from_scope

    my $authority = PAGI::Authority->from_scope($scope);

Uses C<host_from_scope> first.  Only an absent Host permits fallback to
C<< $scope->{server} >>, a one- or two-element C<< [$host, $port] >> tuple.
Server host names and IPv4 use the same grammar as C<validate>; server IPv6 may
be bracketed or unbracketed and is returned bracketed.  A supplied server port
uses the same decimal range rules.  Server-derived port 80 is omitted only for
C<http> and C<ws>, and 443 only for C<https> and C<wss>.  A missing scheme means
C<http>; an unknown scheme has no default port.

Every unusable server fallback croaks with C<scope server cannot provide an
authority>.  Invalid or duplicate Host data is never ignored in favor of this
fallback.

=cut
