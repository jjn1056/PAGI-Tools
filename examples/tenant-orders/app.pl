#!/usr/bin/env perl
#
# An orders API for several tenants, behind middleware that each read the
# request through an object of their own -- a Request where they read the
# body, a PAGI::HTTPConnection where they read only the scope, as Starlette's
# do -- while the route reads the body through its own:
#
#   request_log     reads the headers, and the body ahead to log its size,
#                   then hands on the same body (record_receive);
#   legacy_api_key  rewrites an old client's X-Api-Key into Authorization,
#                   on a copy of the scope;
#   tenant          reads Authorization (the rewritten one) and ?region=;
#   legacy_items    reads an order whose items are one comma-separated
#                   string, as old clients send them, and hands on a body
#                   with a list.
#
# A Request or an HTTPConnection keeps what it parses on itself and writes
# nothing to the scope, so each one reads the scope and the body it was
# handed: the route reads legacy_items' rewritten body, though request_log
# had read the original.
# The same application in Starlette is app.py.
#
# Run:  pagi-server --app examples/tenant-orders/app.pl --port 5000
# Try:  curl -i localhost:5000/orders -H 'Authorization: Bearer k-acme' \
#            -H 'Content-Type: application/json' -d '{"items":["tea","cups"]}'
#       curl -i 'localhost:5000/orders?region=us' -H 'X-Api-Key: k-globex' \
#            -H 'Content-Type: application/json' -d '{"items":"coffee,filters,mugs"}'
#       curl -i localhost:5000/orders -H 'X-Api-Key: k-nobody' -d '{}'   # 401
#       curl localhost:5000/log

use v5.40;
use Future::AsyncAwait;
use JSON::MaybeXS qw(encode_json);
use PAGI::HTTPConnection;
use PAGI::Request;
use PAGI::Utils qw(invoke_app);
use PAGI::Utils::Middleware qw(record_receive);
use PAGI::Tools qw(compose middleware response route);

my %TENANT_FOR_KEY = ('k-acme' => 'acme', 'k-globex' => 'globex');
my @LOG;

# Reads the headers and the body through its own Request, reading the body
# through record_receive's $reading, and hands the application the same body.
sub request_log ($app) {
    return async sub ($scope, $receive, $send) {
        return await $app->($scope, $receive, $send) unless $scope->{type} eq 'http';
        my ($reading, $replaying) = record_receive($receive);
        my $request = PAGI::Request->new($scope, $reading);
        my $caller = defined $request->header('x-api-key') ? 'legacy key'
            : defined $request->header('authorization') ? 'bearer token' : 'anonymous';
        my $bytes = length await $request->body;
        push @LOG, join ' ', $request->method, $request->path, "($caller, $bytes bytes)";
        await $app->($scope, $replaying, $send);
    };
}

# An old client's X-Api-Key becomes Authorization: Bearer, on a copy of the
# scope; the original scope is left as it was. The key is used as a value, so
# a repeated X-Api-Key counts as absent and nothing is rewritten.
sub legacy_api_key ($app) {
    return async sub ($scope, $receive, $send) {
        return await $app->($scope, $receive, $send) unless $scope->{type} eq 'http';
        my $key = PAGI::HTTPConnection->new($scope)->headers->get_single('x-api-key');
        return await $app->($scope, $receive, $send) unless defined $key;
        my @headers = grep { lc($_->[0]) ne 'x-api-key' && lc($_->[0]) ne 'authorization' } @{ $scope->{headers} };
        await $app->({ %$scope, headers => [@headers, ['authorization', "Bearer $key"]] }, $receive, $send);
    };
}

# Reads Authorization and the query through its own PAGI::HTTPConnection,
# which reads the scope without the body: the scope it is given is
# legacy_api_key's copy, so it sees the rewritten header.
sub tenant ($app) {
    return async sub ($scope, $receive, $send) {
        my $conn = PAGI::HTTPConnection->new($scope);
        my ($key) = ($conn->header('authorization') // '') =~ /\ABearer (\S+)\z/;
        my $tenant = defined $key ? $TENANT_FOR_KEY{$key} : undef;
        return await invoke_app(response('JSON', { error => 'unknown API key' }, status => 401,
            headers => ['WWW-Authenticate' => 'Bearer']), $scope, $receive, $send)
            unless defined $tenant;
        await $app->({ %$scope,
            'orders.tenant' => $tenant,
            'orders.region' => $conn->query_param('region') // 'eu',
        }, $receive, $send);
    };
}

# Reads the order through its own Request, and hands the route a scope and a
# receive that deliver the rewritten body (examples/modify-form-post's shape).
sub legacy_items ($app) {
    return async sub ($scope, $receive, $send) {
        my $order = await PAGI::Request->new($scope, $receive)->json;
        $order->{items} = [split /,/, $order->{items}]
            if defined $order->{items} && !ref $order->{items};
        my $body = encode_json($order);
        my $rewritten = { %$scope, headers => [
            (grep { lc($_->[0]) ne 'content-length' && lc($_->[0]) ne 'transfer-encoding' } @{ $scope->{headers} }),
            ['content-length', length $body],
        ] };
        my $delivered = 0;
        await $app->($rewritten, async sub {
            return await $receive->() if $delivered++;
            return { type => 'http.request', body => $body, more => 0 };
        }, $send);
    };
}

# The route's own Request: it reads the body legacy_items handed on, and the
# scope the middleware handed on.
async sub create_order ($request) {
    my $order = await $request->json;
    return response('JSON', {
        tenant     => $request->scope->{'orders.tenant'},
        region     => $request->scope->{'orders.region'},
        items      => $order->{items},
        auth       => $request->header('authorization') =~ s/ .*//r,
        legacy_key => defined $request->header('x-api-key') ? 'still there' : 'gone',
    }, status => 201);
}

compose(
    routes => [
        route('/orders' => \&create_order, methods => ['POST'],
            middleware => [middleware(\&tenant), middleware(\&legacy_items)]),
        route('/log' => sub ($request) { response('JSON', [@LOG]) }),
    ],
    middleware => [middleware(\&request_log), middleware(\&legacy_api_key)],
);
