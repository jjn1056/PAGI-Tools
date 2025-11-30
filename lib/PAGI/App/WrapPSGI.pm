package PAGI::App::WrapPSGI;
use strict;
use warnings;
use experimental 'signatures';
use Future::AsyncAwait;

our $VERSION = '0.001';

=head1 NAME

PAGI::App::WrapPSGI - PSGI-to-PAGI adapter

=head1 SYNOPSIS

    use PAGI::App::WrapPSGI;

    my $psgi_app = sub {
        my ($env) = @_;
        return [200, ['Content-Type' => 'text/plain'], ['Hello']];
    };

    my $wrapper = PAGI::App::WrapPSGI->new(psgi_app => $psgi_app);
    my $pagi_app = $wrapper->to_app;

=head1 DESCRIPTION

PAGI::App::WrapPSGI wraps a PSGI application to make it work with
PAGI servers. It converts PAGI scope to PSGI %env and converts
PSGI responses to PAGI events.

=cut

sub new ($class, %args) {
    my $self = bless {
        psgi_app => $args{psgi_app},
    }, $class;
    return $self;
}

sub to_app ($self) {
    my $psgi_app = $self->{psgi_app};

    return async sub ($scope, $receive, $send) {
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

        # TODO: Implement in Step 9
        # 1. Build PSGI %env from $scope
        # 2. Collect body from $receive into psgi.input
        # 3. Call $psgi_app->(\%env)
        # 4. Convert response to http.response.* events

        my $env = $self->_build_env($scope);

        # Collect request body
        my $body = '';
        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            $body .= $event->{body} // '';
            last unless $event->{more};
        }

        # Create psgi.input
        open my $input, '<', \$body or die $!;
        $env->{'psgi.input'} = $input;

        # Call PSGI app
        my $response = $psgi_app->($env);

        # Handle response
        await $self->_send_response($send, $response);
    };
}

sub _build_env ($self, $scope) {
    # TODO: Implement in Step 9
    my %env = (
        REQUEST_METHOD  => $scope->{method},
        SCRIPT_NAME     => $scope->{root_path},
        PATH_INFO       => $scope->{path},
        QUERY_STRING    => $scope->{query_string},
        SERVER_PROTOCOL => 'HTTP/' . $scope->{http_version},
        'psgi.version'    => [1, 1],
        'psgi.url_scheme' => $scope->{scheme},
        'psgi.errors'     => \*STDERR,
        'psgi.multithread'  => 0,
        'psgi.multiprocess' => 0,
        'psgi.run_once'     => 0,
        'psgi.streaming'    => 1,
        'psgi.nonblocking'  => 1,
    );

    # Add headers
    for my $header (@{$scope->{headers}}) {
        my ($name, $value) = @$header;
        my $key = uc($name);
        $key =~ s/-/_/g;
        if ($key eq 'CONTENT_TYPE') {
            $env{CONTENT_TYPE} = $value;
        } elsif ($key eq 'CONTENT_LENGTH') {
            $env{CONTENT_LENGTH} = $value;
        } else {
            $env{"HTTP_$key"} = $value;
        }
    }

    # Server/client info
    if ($scope->{server}) {
        $env{SERVER_NAME} = $scope->{server}[0];
        $env{SERVER_PORT} = $scope->{server}[1];
    }
    if ($scope->{client}) {
        $env{REMOTE_ADDR} = $scope->{client}[0];
        $env{REMOTE_PORT} = $scope->{client}[1];
    }

    return \%env;
}

async sub _send_response ($self, $send, $response) {
    # TODO: Implement in Step 9
    my ($status, $headers, $body) = @$response;

    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [ map { [lc($_->[0]), $_->[1]] } @{_pairs($headers)} ],
    });

    if (ref $body eq 'ARRAY') {
        my $content = join '', @$body;
        await $send->({
            type => 'http.response.body',
            body => $content,
            more => 0,
        });
    } elsif (ref $body eq 'CODE') {
        # Streaming response
        $body->(sub {
            # TODO: Handle streaming callback
        });
    } else {
        # Filehandle
        local $/;
        my $content = <$body>;
        await $send->({
            type => 'http.response.body',
            body => $content // '',
            more => 0,
        });
    }
}

sub _pairs ($arrayref) {
    my @pairs;
    for (my $i = 0; $i < @$arrayref; $i += 2) {
        push @pairs, [$arrayref->[$i], $arrayref->[$i+1]];
    }
    return \@pairs;
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Server>, L<PSGI>

=head1 AUTHOR

John Napiorkowski E<lt>jjnapiork@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
