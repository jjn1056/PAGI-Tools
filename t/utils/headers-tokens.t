use strict;
use warnings;
use Test2::V0;
use PAGI::Utils::Headers qw(parse_header_tokens merge_vary);

is parse_header_tokens(undef), [], 'missing token list is empty';
is parse_header_tokens(" , \t, "), [], 'empty list members are ignored';
is parse_header_tokens('GET,, HEAD, GET'), ['GET', 'HEAD', 'GET'],
    'token order, spelling and repetition are retained';
is parse_header_tokens("\tGET \t,\tHEAD\t"), ['GET', 'HEAD'],
    'only surrounding SP and HTAB are trimmed';
is parse_header_tokens('GET, "HEAD"'), undef, 'quoted member is malformed';
is parse_header_tokens("GET,\nHEAD"), undef, 'newline is not optional whitespace';
like dies { parse_header_tokens('GET, "HEAD"', raise_on_error => 1) },
    qr/parse_header_tokens.*malformed/i, 'malformed list can raise';
is parse_header_tokens(undef, raise_on_error => 1), [], 'missing list does not raise';
like dies { parse_header_tokens([], raise_on_error => 0) },
    qr/parse_header_tokens.*scalar/i, 'reference input is a programming error';
like dies { parse_header_tokens('GET', unknown => 1) },
    qr/unknown option/i, 'unknown parser option is rejected';

is merge_vary([],), '', 'empty composition is empty';
is merge_vary(['Origin', 'accept-encoding'], 'Accept-Encoding', 'Accept'),
    'Origin, accept-encoding, Accept', 'first spelling and order win';
is merge_vary(['Origin, *'], 'Accept'), '*', 'existing wildcard dominates';
is merge_vary(['Origin'], 'Accept', '*'), '*', 'added wildcard dominates';
like dies { merge_vary(['*', '"bad"'], 'Accept') },
    qr/merge_vary.*malformed/i, 'wildcard does not hide a malformed later field';
is merge_vary([' , ', 'Origin,, Accept'], 'accept'),
    'Origin, Accept', 'empty members are ignored across fields';
like dies { merge_vary(['Origin, "Accept"'], 'Accept-Encoding') },
    qr/merge_vary.*malformed/i, 'malformed existing member raises';
like dies { merge_vary(['Origin'], 'bad name') },
    qr/merge_vary.*field name/i, 'invalid added name raises';
like dies { merge_vary('Origin', 'Accept') },
    qr/merge_vary.*arrayref/i, 'existing values must be an arrayref';
like dies { merge_vary([undef], 'Accept') },
    qr/merge_vary.*scalar/i, 'existing field value must be a scalar';

done_testing;
