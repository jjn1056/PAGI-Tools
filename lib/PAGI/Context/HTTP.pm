package PAGI::Context::HTTP;

use strict;
use warnings;
use Carp qw(croak);

our @ISA = ('PAGI::Context');

=encoding UTF-8

=head1 NAME

PAGI::Context::HTTP - HTTP-specific context subclass

=head1 DESCRIPTION

Returned by C<< PAGI::Context->new(...) >> when C<< $scope->{type} >> is
C<'http'>. Adds lazy accessors for L<PAGI::Request> and L<PAGI::Response>,
plus an HTTP C<method> accessor.

Inherits all shared methods from L<PAGI::Context>.

=head1 METHODS

=head2 request

    my $req = $ctx->request;

Returns a L<PAGI::Request> instance. Lazy-constructed and cached.

=head2 response

    my $res = $ctx->response;

Returns a detached L<PAGI::Response> accumulator. Lazy-constructed and cached
for the lifetime of the context. The response holds no connection — it is a
pure value object you mutate via the chainer methods (C<status>, C<header>,
C<json>, etc.) and then pass to L</respond> when ready to send.

=head2 respond

    $ctx->respond($res);

Guarded send. Sends the L<PAGI::Response> value C<$res> over this request's
connection, marks the request as done, and returns a L<Future> that resolves
when all protocol events have been emitted.

Dies (C<croak>) if called a second time on the same request — one HTTP response
per request. The sent state is stored in the shared scope under
C<pagi.response.sent> so middleware and the application share a single flag.

Delegates to the unguarded primitive C<< $res->respond($send) >> after setting
the flag.

=head2 method

    my $method = $ctx->method;    # 'GET', 'POST', etc.

Returns the HTTP method from the scope.

=head2 req

    my $req = $ctx->req;

Alias for C<request>.

=head2 resp

    my $res = $ctx->resp;

Alias for C<response>.

=cut

sub request {
    my ($self) = @_;
    return $self->{_request} //= do {
        require PAGI::Request;
        PAGI::Request->new($self->{scope}, $self->{receive});
    };
}

sub response {
    my ($self) = @_;
    return $self->{_response} //= do {
        require PAGI::Response;
        PAGI::Response->new($self->{scope});    # detached accumulator; no $send
    };
}

sub respond {
    my ($self, $res) = @_;
    my $scope = $self->{scope};
    croak("response already sent") if $scope && $scope->{'pagi.response.sent'};
    $scope->{'pagi.response.sent'} = 1 if $scope;
    return $res->respond($self->{send});
}

sub method { shift->{scope}{method} }

sub req  { shift->request }
sub resp { shift->response }

1;

__END__

=head1 SEE ALSO

L<PAGI::Context>, L<PAGI::Request>, L<PAGI::Response>

=cut
