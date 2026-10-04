use strict;
use warnings;
use Test2::V0;
use lib 'lib';
use PAGI::ErrorContext qw(error_context);
use PAGI::Request;
use PAGI::Request::BodyError;

{
    package Local::Coded;
    sub new { my ($class, %args) = @_; bless {%args}, $class }
    sub status_code { $_[0]{status} }
    sub message { 'SELECT * FROM secrets' }
    sub client_message { my $m = $_[0]{client}; die "boom\n" if $m && $m eq 'die'; $m }
}

sub scope_with { my (%error) = @_; return { type => 'http', 'pagi.error' => {%error} } }

subtest 'construction from a scope, a Request, or any ->scope object' => sub {
    my $scope = scope_with(exception => "x\n", status => 500, development => 0);
    isa_ok(PAGI::ErrorContext->new($scope), ['PAGI::ErrorContext']);
    is error_context(PAGI::Request->new($scope, sub {}))->status, 500, 'a Request';
    like dies { PAGI::ErrorContext->new({ type => 'http' }) },
        qr/needs the scope of an ErrorHandler handler/, 'no pagi.error dies';
};

subtest 'status, reason and the error classes' => sub {
    my $e = error_context(scope_with(exception => 'x', status => 413, development => 0));
    is [$e->status, $e->reason, $e->is_client_error, $e->is_server_error],
        [413, 'Content Too Large', 1, 0];
    is error_context(scope_with(exception => 'x', status => 499, development => 0))->reason,
        'Client Error', 'an unregistered 4xx';
    is error_context(scope_with(exception => 'x', status => 599, development => 0))->reason,
        'Server Error', 'an unregistered 5xx';
};

subtest 'message: a 4xx client_message, never message; a 5xx reason' => sub {
    my $body = PAGI::Request::BodyError->new(message => 'The request body is not valid JSON.');
    is error_context(scope_with(exception => $body, status => 400, development => 0))->message,
        'The request body is not valid JSON.', 'BodyError client_message';
    is error_context(scope_with(exception => Local::Coded->new, status => 404, development => 0))->message,
        'Not Found', 'a plain message method is never shown';
    is error_context(scope_with(exception => Local::Coded->new(client => 'nope'), status => 500,
        development => 0))->message, 'Internal Server Error', 'a 5xx shows only the reason';
};

subtest 'client_message that dies or misbehaves falls back to the reason' => sub {
    for my $client ('die', '', [1]) {
        is error_context(scope_with(exception => Local::Coded->new(client => $client), status => 409,
            development => 0))->message, 'Conflict', 'fallback';
    }
};

subtest 'detail only in development' => sub {
    is error_context(scope_with(exception => "db password wrong\n", status => 500, development => 0))->detail,
        undef, 'production';
    is error_context(scope_with(exception => "db password wrong\n", status => 500, development => 1))->detail,
        "db password wrong\n", 'development';
};

subtest 'default: plain text, the status, no-store' => sub {
    my $prod = error_context(scope_with(exception => "db\n", status => 500, development => 0))->default;
    isa_ok($prod, ['PAGI::Response']);
    is [$prod->status, $prod->body, $prod->header('Cache-Control'), $prod->header('Content-Type')],
        [500, 'Internal Server Error', 'no-store', 'text/plain; charset=utf-8'];
    my $dev = error_context(scope_with(exception => "db\n", status => 500, development => 1))->default;
    is $dev->body, "Internal Server Error\n\ndb\n", 'development appends the detail';
};

subtest 'error_context is exported only on request' => sub {
    package Local::NoImport;
    use PAGI::ErrorContext;
    ::ok(!Local::NoImport->can('error_context'), 'nothing is exported by default');
};

done_testing;
