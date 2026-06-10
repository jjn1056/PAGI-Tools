package PAGI::Tools;

use strict;
use warnings;

our $VERSION = '0.002000';

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Tools - Application toolkit for the PAGI specification

=head1 DESCRIPTION

PAGI-Tools is the application-side toolkit for L<PAGI|https://github.com/jjn1056/pagi>,
the Perl Asynchronous Gateway Interface. It collects everything an
application author needs on top of a PAGI-compliant server:

=over 4

=item * L<PAGI::Middleware> and the C<PAGI::Middleware::*> suite

=item * C<PAGI::App::*> - ready-made apps (static files, routers, proxies,
WebSocket chat/echo, PSGI bridging)

=item * L<PAGI::Endpoint::HTTP>, L<PAGI::Endpoint::Router>,
L<PAGI::Endpoint::SSE>, L<PAGI::Endpoint::WebSocket> - high-level endpoint
framework

=item * L<PAGI::Request>, L<PAGI::Response>, L<PAGI::Context> - request
processing and ergonomics

=item * L<PAGI::Test::Client> and friends - in-process test utilities for
PAGI applications

=item * L<PAGI::Utils> - composition and lifespan helpers; its
L<to_app|PAGI::Utils/to_app> coercion is what lets every composition
point above accept component objects and class names directly

=back

The reference server lives in the C<PAGI-Server> distribution; the
protocol specification lives in the C<PAGI> distribution.

=head1 SEE ALSO

L<PAGI::Tutorial> (the protocol tutorial, in the C<PAGI> distribution),
L<PAGI::Tools::Tutorial> (this distribution's helpers guide),
L<PAGI::Cookbook>, L<PAGI::Spec>,
L<PAGI::Server::Runner> - runs PAGI applications from the command line
(ships with the PAGI-Server distribution)

=head1 AUTHOR

John Napiorkowski <jjnapiork@cpan.org>

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it
under the same terms as the Artistic License 2.0.

=cut
