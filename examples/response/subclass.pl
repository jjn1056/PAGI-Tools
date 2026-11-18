#!/usr/bin/env perl
# A response class of your own, one for each place a subclass plugs in:
#
#   /csv     rows as CSV: Text's as_text makes the text, Text encodes it
#   /sorted  JSON with its keys sorted: JSON's json_encoder
#   /latin1  text in another charset: the base's prepare_body
#   /timed   a body send timed, to STDERR: send_body, wrapped
#
#   pagi-server --app examples/response/subclass.pl --port 5000
#   curl -i http://localhost:5000/csv
#   curl -i http://localhost:5000/sorted
#   curl -i http://localhost:5000/latin1
#   curl -i http://localhost:5000/timed

use v5.40;
use utf8;
use Future::AsyncAwait;
use Time::HiRes ();
use PAGI::Response::Text;

# Rows in, CSV out, as UTF-8 text/csv. Only the text is ours to make.
package CSV {
    use v5.40;
    use parent 'PAGI::Response::Text';

    sub default_content_type { 'text/csv' }   # sent as text/csv; charset=utf-8

    sub as_text ($self, $rows) {
        return join '', map { join(',', @$_) . "\r\n" } @$rows;
    }
}

# JSON whose keys always come out in the same order.
package SortedJSON {
    use v5.40;
    use parent 'PAGI::Response::JSON';
    use JSON::MaybeXS ();

    sub json_encoder ($self) {
        return JSON::MaybeXS->new(utf8 => 1, allow_nonref => 1, convert_blessed => 1, canonical => 1);
    }
}

# Text in Latin-1: the base adds no charset, so we encode and name it.
package Latin1 {
    use v5.40;
    use parent 'PAGI::Response';
    use Encode ();

    sub default_content_type { 'text/plain; charset=iso-8859-1' }

    # A character Latin-1 can't hold croaks, rather than going out as '?'.
    sub prepare_body ($self, $args) {
        return Encode::encode('iso-8859-1', $args->{content} // '', Encode::FB_CROAK | Encode::LEAVE_SRC);
    }
}

# Any text response, with its body's send timed.
package TimedText {
    use v5.40;
    use parent 'PAGI::Response::Text';

    sub send_body ($self, $send) {
        my $started = Time::HiRes::time();
        return $self->SUPER::send_body($send)->on_done(sub {
            warn sprintf "body of %d bytes sent in %.3fms\n", length $self->body, 1000 * (Time::HiRes::time() - $started);
        });
    }
}

my $app = async sub ($scope, $receive, $send) {
    die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';

    my $path = $scope->{path};
    my $response = $path eq '/csv'    ? CSV->new(content => [['name', 'city'], ['Zoë', 'Zürich']])
                 : $path eq '/sorted' ? SortedJSON->new(content => { b => 2, a => 1, c => 3 })
                 : $path eq '/latin1' ? Latin1->new(content => "Grüße\n")
                 : $path eq '/timed'  ? TimedText->new(content => "Timed, see the server's STDERR\n")
                 :                      PAGI::Response::Text->new(status => 404, content => "Not Found\n");

    await $response->call($scope, $receive, $send);
};

$app;
