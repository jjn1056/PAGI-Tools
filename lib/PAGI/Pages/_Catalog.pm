package PAGI::Pages::_Catalog;

use strict;
use warnings;

=encoding UTF-8

=head1 NAME

PAGI::Pages::_Catalog - private checked-in HTTP error page catalog

=head1 DESCRIPTION

Provides fresh descriptor, method-name, and exported page-function-name
snapshots to L<PAGI::Pages>. This private module performs no runtime registry
lookup.

=cut

my %ERRORS = (
    400 => {
        status => 400, method => 'bad_request', title => 'Bad Request',
        detail => 'The server could not understand the request.',
    },
    401 => {
        status => 401, method => 'unauthorized', title => 'Unauthorized',
        detail => 'Authentication is required to access this resource.',
    },
    402 => {
        status => 402, method => 'payment_required', title => 'Payment Required',
        detail => 'Payment is required to access this resource.',
    },
    403 => {
        status => 403, method => 'forbidden', title => 'Forbidden',
        detail => 'You do not have permission to access this resource.',
    },
    404 => {
        status => 404, method => 'not_found', title => 'Not Found',
        detail => 'The requested resource was not found.',
    },
    405 => {
        status => 405, method => 'method_not_allowed', title => 'Method Not Allowed',
        detail => 'The request method is not allowed for this resource.',
    },
    406 => {
        status => 406, method => 'not_acceptable', title => 'Not Acceptable',
        detail => 'The requested response representation is not available.',
    },
    407 => {
        status => 407, method => 'proxy_authentication_required', title => 'Proxy Authentication Required',
        detail => 'Proxy authentication is required to access this resource.',
    },
    408 => {
        status => 408, method => 'request_timeout', title => 'Request Timeout',
        detail => 'The server timed out waiting for the request.',
    },
    409 => {
        status => 409, method => 'conflict', title => 'Conflict',
        detail => 'The request conflicts with the current state of the resource.',
    },
    410 => {
        status => 410, method => 'gone', title => 'Gone',
        detail => 'The requested resource is no longer available.',
    },
    411 => {
        status => 411, method => 'length_required', title => 'Length Required',
        detail => 'The request must include a Content-Length header.',
    },
    412 => {
        status => 412, method => 'precondition_failed', title => 'Precondition Failed',
        detail => 'A precondition for this request was not met.',
    },
    413 => {
        status => 413, method => 'content_too_large', title => 'Content Too Large',
        detail => 'The request content is too large for the server to process.',
    },
    414 => {
        status => 414, method => 'uri_too_long', title => 'URI Too Long',
        detail => 'The request URI is too long for the server to process.',
    },
    415 => {
        status => 415, method => 'unsupported_media_type', title => 'Unsupported Media Type',
        detail => 'The request content type is not supported.',
    },
    416 => {
        status => 416, method => 'range_not_satisfiable', title => 'Range Not Satisfiable',
        detail => 'The requested range cannot be satisfied.',
    },
    417 => {
        status => 417, method => 'expectation_failed', title => 'Expectation Failed',
        detail => 'The server cannot meet the request expectation.',
    },
    421 => {
        status => 421, method => 'misdirected_request', title => 'Misdirected Request',
        detail => 'The request was sent to a server that cannot respond for this authority.',
    },
    422 => {
        status => 422, method => 'unprocessable_content', title => 'Unprocessable Content',
        detail => 'The request content could not be processed.',
    },
    423 => {
        status => 423, method => 'locked', title => 'Locked',
        detail => 'The requested resource is locked.',
    },
    424 => {
        status => 424, method => 'failed_dependency', title => 'Failed Dependency',
        detail => 'The request failed because a required operation failed.',
    },
    425 => {
        status => 425, method => 'too_early', title => 'Too Early',
        detail => 'The server is unwilling to process this request yet.',
    },
    426 => {
        status => 426, method => 'upgrade_required', title => 'Upgrade Required',
        detail => 'The client must use a different protocol for this resource.',
    },
    428 => {
        status => 428, method => 'precondition_required', title => 'Precondition Required',
        detail => 'The request must include a precondition.',
    },
    429 => {
        status => 429, method => 'too_many_requests', title => 'Too Many Requests',
        detail => 'Too many requests have been received in a short time.',
    },
    431 => {
        status => 431, method => 'request_header_fields_too_large', title => 'Request Header Fields Too Large',
        detail => 'The request header fields are too large.',
    },
    451 => {
        status => 451, method => 'unavailable_for_legal_reasons', title => 'Unavailable For Legal Reasons',
        detail => 'The resource is unavailable for legal reasons.',
    },
    500 => {
        status => 500, method => 'internal_server_error', title => 'Internal Server Error',
        detail => 'The server encountered an unexpected condition.',
    },
    501 => {
        status => 501, method => 'not_implemented', title => 'Not Implemented',
        detail => 'The server does not support this request method.',
    },
    502 => {
        status => 502, method => 'bad_gateway', title => 'Bad Gateway',
        detail => 'The server received an invalid response from an upstream server.',
    },
    503 => {
        status => 503, method => 'service_unavailable', title => 'Service Unavailable',
        detail => 'The server is temporarily unable to handle the request.',
    },
    504 => {
        status => 504, method => 'gateway_timeout', title => 'Gateway Timeout',
        detail => 'The server did not receive a timely response from an upstream server.',
    },
    505 => {
        status => 505, method => 'http_version_not_supported', title => 'HTTP Version Not Supported',
        detail => 'The server does not support this HTTP version.',
    },
    506 => {
        status => 506, method => 'variant_also_negotiates', title => 'Variant Also Negotiates',
        detail => 'The server found a configuration error while negotiating a response.',
    },
    507 => {
        status => 507, method => 'insufficient_storage', title => 'Insufficient Storage',
        detail => 'The server cannot store the representation needed to complete the request.',
    },
    508 => {
        status => 508, method => 'loop_detected', title => 'Loop Detected',
        detail => 'The server detected an infinite loop while processing the request.',
    },
    511 => {
        status => 511, method => 'network_authentication_required', title => 'Network Authentication Required',
        detail => 'Network authentication is required before access is granted.',
    },
);

sub _entry {
    my ($class, $status) = @_;

    return unless exists $ERRORS{$status};
    return { %{ $ERRORS{$status} } };
}

sub _code_for_method {
    my ($class, $method) = @_;

    return unless defined $method;
    for my $status (sort { $a <=> $b } keys %ERRORS) {
        return $status if $ERRORS{$status}{method} eq $method;
    }
    return;
}

sub _named_methods {
    return [ map { $ERRORS{$_}{method} } sort { $a <=> $b } keys %ERRORS ];
}

1;
