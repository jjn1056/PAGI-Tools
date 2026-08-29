use strict;
use warnings;

use Test::More;

use PAGI::Pages::_Catalog;

my @named = (
    [400 => 'bad_request', 'Bad Request'],
    [401 => 'unauthorized', 'Unauthorized'],
    [402 => 'payment_required', 'Payment Required'],
    [403 => 'forbidden', 'Forbidden'],
    [404 => 'not_found', 'Not Found'],
    [405 => 'method_not_allowed', 'Method Not Allowed'],
    [406 => 'not_acceptable', 'Not Acceptable'],
    [407 => 'proxy_authentication_required', 'Proxy Authentication Required'],
    [408 => 'request_timeout', 'Request Timeout'],
    [409 => 'conflict', 'Conflict'],
    [410 => 'gone', 'Gone'],
    [411 => 'length_required', 'Length Required'],
    [412 => 'precondition_failed', 'Precondition Failed'],
    [413 => 'content_too_large', 'Content Too Large'],
    [414 => 'uri_too_long', 'URI Too Long'],
    [415 => 'unsupported_media_type', 'Unsupported Media Type'],
    [416 => 'range_not_satisfiable', 'Range Not Satisfiable'],
    [417 => 'expectation_failed', 'Expectation Failed'],
    [421 => 'misdirected_request', 'Misdirected Request'],
    [422 => 'unprocessable_content', 'Unprocessable Content'],
    [423 => 'locked', 'Locked'],
    [424 => 'failed_dependency', 'Failed Dependency'],
    [425 => 'too_early', 'Too Early'],
    [426 => 'upgrade_required', 'Upgrade Required'],
    [428 => 'precondition_required', 'Precondition Required'],
    [429 => 'too_many_requests', 'Too Many Requests'],
    [431 => 'request_header_fields_too_large', 'Request Header Fields Too Large'],
    [451 => 'unavailable_for_legal_reasons', 'Unavailable For Legal Reasons'],
    [500 => 'internal_server_error', 'Internal Server Error'],
    [501 => 'not_implemented', 'Not Implemented'],
    [502 => 'bad_gateway', 'Bad Gateway'],
    [503 => 'service_unavailable', 'Service Unavailable'],
    [504 => 'gateway_timeout', 'Gateway Timeout'],
    [505 => 'http_version_not_supported', 'HTTP Version Not Supported'],
    [506 => 'variant_also_negotiates', 'Variant Also Negotiates'],
    [507 => 'insufficient_storage', 'Insufficient Storage'],
    [508 => 'loop_detected', 'Loop Detected'],
    [511 => 'network_authentication_required', 'Network Authentication Required'],
);

for my $named (@named) {
    my ($code, $method, $title) = @$named;
    my $entry = PAGI::Pages::_Catalog->_entry($code);

    is_deeply(
        [sort keys %$entry],
        [qw(detail method status title)],
        "$method entry has the complete default fields",
    );
    is($entry->{status}, $code, "$method maps from $code");
    is($entry->{method}, $method, "$method method is exact");
    is($entry->{title}, $title, "$method has the registered title");
    ok(length($entry->{detail}), "$method has safe detail");
    is(PAGI::Pages::_Catalog->_code_for_method($method), $code,
        "$method reverse lookup");
}

my $entry = PAGI::Pages::_Catalog->_entry(400);
$entry->{detail} = 'changed by a caller';
is(
    PAGI::Pages::_Catalog->_entry(400)->{detail},
    'The server could not understand the request.',
    'entries are fresh copies',
);

my $methods = PAGI::Pages::_Catalog->_named_methods;
is_deeply(
    $methods,
    [map { $_->[1] } @named],
    'named methods are in numeric status order',
);
$methods->[0] = 'changed_by_a_caller';
is(
    PAGI::Pages::_Catalog->_named_methods->[0],
    'bad_request',
    'named methods are a fresh copy',
);

my $page_functions = PAGI::Pages::_Catalog->_named_page_functions;
is_deeply(
    $page_functions,
    [map { $_->[1] . '_page' } @named],
    'catalog page function names are in numeric status order',
);
$page_functions->[0] = 'changed_by_a_caller_page';
is(
    PAGI::Pages::_Catalog->_named_page_functions->[0],
    'bad_request_page',
    'catalog page function names are a fresh copy',
);

ok(!PAGI::Pages::_Catalog->_entry(418), 'unused 418 is absent');
ok(!PAGI::Pages::_Catalog->_entry(510), 'obsolete 510 is absent');
ok(!defined PAGI::Pages::_Catalog->_entry(499), 'unlisted status is absent');
ok(!defined PAGI::Pages::_Catalog->_code_for_method('teapot'),
    'unlisted method is absent');

done_testing;
