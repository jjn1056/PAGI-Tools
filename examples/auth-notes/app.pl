use v5.40;
use Future::AsyncAwait;
use NotesDemo::TokenStore;
use NotesDemo::Library;
use PAGI::Auth qw(auth auth_result unauth_result www_authenticate);
use PAGI::Auth::SimpleUser;
use PAGI::Middleware::Authentication;
use PAGI::Compose qw(compose);
use PAGI::Response qw(json_response);
use PAGI::Routing qw(route middleware);

sub build_authentication ($token_store) {
    return PAGI::Middleware::Authentication->new(
        backend => async sub ($request) {
            my @authorization = $request->header_all('Authorization');
            return unauth_result() unless @authorization;

            my $token;
            if (@authorization == 1) {
                my ($scheme) = $authorization[0] =~ /\A(\S+)/;
                return unauth_result() if defined($scheme) && lc($scheme) ne 'bearer';
                ($token) = $authorization[0] =~ /\ABearer +([A-Za-z0-9._~+\/-]+=*)\z/i;
            }
            # Application convention, shared with the JWT examples.
            return unauth_result(failure => {
                code => 'malformed_authorization',
                message => 'Expected one Authorization header containing a Bearer token.',
            }) unless defined $token;

            # A failed store Future propagates; it is not a rejected credential.
            my $record = await $token_store->find_active($token);
            return unauth_result(failure => {
                message => 'The token was rejected.',
            }) unless $record;

            return auth_result(
                user => PAGI::Auth::SimpleUser->new(
                    identity => $record->{user_id},
                    display_name => $record->{display_name},
                ),
                scopes => $record->{scopes},
            );
        },
    );
}

# An ordinary response builder: handlers below explicitly choose when to use it.
sub authentication_notice ($context) {
    my $failure = $context->failure;
    my $malformed = $failure && ($failure->code // '') eq 'malformed_authorization';
    my @params = (realm => 'notes');
    push @params, error => ($malformed ? 'invalid_request' : 'invalid_token') if $failure;
    return json_response(
        { error => $malformed ? 'Malformed Authorization header.' : 'Please authenticate.' },
        status => $malformed ? 400 : 401,
        headers => ['WWW-Authenticate' => www_authenticate('Bearer', @params)],
    );
}

sub build_app ($token_store, $notes) {
    return compose(
        middleware => [middleware(build_authentication($token_store))],
        routes => [
            route('/notes' => async sub ($request) {
                my $items = await $notes->all_published;
                return json_response({
                    viewer => auth($request)->user->display_name || 'Guest',
                    notes => $items,
                });
            }, methods => ['GET']),

            route('/me' => sub ($request) {
                my $context = auth($request);
                return authentication_notice($context) unless $context->user->is_authenticated;
                return json_response({
                    user_id => $context->user->identity,
                    display_name => $context->user->display_name,
                    scopes => $context->credentials->scopes,
                });
            }, methods => ['GET']),

            route('/notes' => async sub ($request) {
                my $context = auth($request);
                return authentication_notice($context) unless $context->user->is_authenticated;
                unless ($context->credentials->has_all('notes:read', 'notes:write')) {
                    return json_response(
                        { error => 'Publishing requires read and write access.' },
                        status => 403,
                        headers => ['WWW-Authenticate' => www_authenticate('Bearer',
                            realm => 'notes', error => 'insufficient_scope',
                            scope => 'notes:read notes:write',
                        )],
                    );
                }
                my $data = await $request->json;
                unless (ref($data) eq 'HASH' && defined($data->{text})
                    && !ref($data->{text}) && $data->{text} =~ /\S/) {
                    return json_response({error => 'A nonempty text string is required.'}, status => 400);
                }
                my $note = await $notes->publish($context->user->identity, $data);
                return json_response($note, status => 201);
            }, methods => ['POST']),

            route('/notes/export' => async sub ($request) {
                my $context = auth($request);
                unless ($context->credentials->has('notes:read')) {
                    return authentication_notice($context) unless $context->user->is_authenticated;
                    return json_response(
                        { error => 'Export requires read access.' },
                        status => 403,
                        headers => ['WWW-Authenticate' => www_authenticate('Bearer',
                            realm => 'notes', error => 'insufficient_scope', scope => 'notes:read',
                        )],
                    );
                }
                return json_response({notes => await $notes->all_published});
            }, methods => ['GET']),
        ],
    );
}

build_app(NotesDemo::TokenStore->new, NotesDemo::Library->new);
