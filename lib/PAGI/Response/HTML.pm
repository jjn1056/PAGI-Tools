package PAGI::Response::HTML;

use v5.24;
use warnings;
use parent 'PAGI::Response::Text';

sub default_content_type { return 'text/html; charset=utf-8' }

1;

=encoding UTF-8

=head1 NAME

PAGI::Response::HTML - a response whose content is HTML, sent as UTF-8

=head1 SYNOPSIS

    use v5.40;
    use utf8;
    use Future::AsyncAwait;
    use PAGI::Response::HTML;

    my $app = async sub ($scope, $receive, $send) {
        die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
        my $response = PAGI::Response::HTML->new(content => "<p>Hello, 🌍!</p>\n");
        await $response->call($scope, $receive, $send);
    };

    $app;

=head1 DESCRIPTION

A L<PAGI::Response::Text> whose type is HTML: C<text/html; charset=utf-8>
unless you give one. The content is characters, encoded as UTF-8 when you
build the response, and everything else, from C<content_type> to C<call>, is
Text's.

HTML sends the markup you give it as it is. It doesn't escape or sanitize
anything, so a value from a request that goes into the markup is yours to
escape, or build the page with a template engine that does.

=head1 METHODS

=head2 default_content_type

    my $type = $response->default_content_type;   # 'text/html; charset=utf-8'

=head1 SEE ALSO

L<PAGI::Response::Text>, L<PAGI::Response>

=cut
