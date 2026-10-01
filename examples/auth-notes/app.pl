use v5.40;
use Future::AsyncAwait;
use NotesDemo::Library;
use NotesDemo::TokenStore;
use PAGI::Auth qw(auth auth_result unauth_result www_authenticate);
use PAGI::Auth::SimpleUser;
use PAGI::Compose qw(compose);
use PAGI::Response qw(json_response);
use PAGI::Routing qw(middleware route);

# The authentication backend: turns a Bearer token into a user and grants.
sub token_backend ($tokens) {
    return async sub ($request) {
        my $token;
        my $parsed = eval {
            $token = $request->bearer_token(raise_on_error => 1);
            1;
        };
        return unauth_result(failure => {
            code => 'malformed_authorization',
            message => 'Expected one Authorization header containing a Bearer token.',
        }) unless $parsed;
        return unauth_result() unless defined $token;

        # A failed store Future propagates; it is not a rejected credential.
        my $record = await $tokens->find_active($token);
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
    };
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

# Public: anyone can read the notes; a known token only changes the viewer.
async sub list_notes ($request, $notes) {
    return json_response({
        viewer => auth($request)->user->display_name || 'Guest',
        notes => await $notes->all_published,
    });
}

sub me ($request) {
    my $context = auth($request);
    return authentication_notice($context) unless $context->user->is_authenticated;
    return json_response({
        user_id => $context->user->identity,
        display_name => $context->user->display_name,
        scopes => $context->credentials->scopes,
    });
}

async sub publish_note ($request, $notes) {
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
}

async sub export_notes ($request, $notes) {
    my $context = auth($request);
    return authentication_notice($context) unless $context->user->is_authenticated;
    unless ($context->credentials->has('notes:read')) {
        return json_response(
            { error => 'Export requires read access.' },
            status => 403,
            headers => ['WWW-Authenticate' => www_authenticate('Bearer',
                realm => 'notes', error => 'insufficient_scope', scope => 'notes:read',
            )],
        );
    }
    return json_response({notes => await $notes->all_published});
}

# The services are passed in, so a test can supply its own.
sub build_app ($tokens, $notes) {
    return compose(
        middleware => [middleware('Authentication', backend => token_backend($tokens))],
        routes => [
            route('/notes' => sub ($request) { list_notes($request, $notes) }, methods => ['GET']),
            route('/notes' => sub ($request) { publish_note($request, $notes) }, methods => ['POST']),
            route('/notes/export' => sub ($request) { export_notes($request, $notes) }, methods => ['GET']),
            route('/me' => \&me, methods => ['GET']),
        ],
    );
}

build_app(NotesDemo::TokenStore->new, NotesDemo::Library->new);
