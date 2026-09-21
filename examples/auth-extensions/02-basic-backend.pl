use v5.40;
use PAGI::Auth qw(auth unauth_result www_authenticate);
use PAGI::Auth::SimpleUser;
use PAGI::Compose qw(compose);
use PAGI::Middleware::Authentication;
use PAGI::Response qw(json_response);
use PAGI::Routing qw(route middleware);

{
    package AuthExtensions::BasicBackend;
    sub new {
        my ($class, %args) = @_;
        return bless { verify => $args{verify} }, $class;
    }
    sub authenticate {
        my ($self, $request) = @_;
        my @values = $request->header_all('Authorization');
        return PAGI::Auth::unauth_result() unless @values;
        return PAGI::Auth::unauth_result(failure => {
            code => 'malformed_authorization', message => 'Supply one Authorization field.',
        }) unless @values == 1;
        return PAGI::Auth::unauth_result() unless $values[0] =~ /\ABasic(?: |\z)/i;
        my ($username, $password) = $request->basic_auth;
        return PAGI::Auth::unauth_result(failure => {
            message => 'Credentials were not accepted.',
        }) unless defined($username) && defined($password)
            && $username !~ /[^\x20-\x7e]/ && $password !~ /[^\x20-\x7e]/;
        return PAGI::Auth::unauth_result(failure => {
            message => 'Credentials were not accepted.',
        }) unless $self->{verify}->($username, $password);
        return PAGI::Auth::auth_result(
            user => PAGI::Auth::SimpleUser->new(
                identity => $username, display_name => 'Ada',
            ),
            scopes => ['staff:read'],
        );
    }
}

# Fixed, public learning fixture. A production application supplies a service
# that verifies credentials and does not keep a clear-text password in the app.
my $verify_fixture = sub ($username, $password) {
    return $username eq 'ada' && $password eq 'test';
};
my $backend = AuthExtensions::BasicBackend->new(verify => $verify_fixture);
my $authentication = PAGI::Middleware::Authentication->new(backend => $backend);

compose(
    middleware => [middleware($authentication)],
    routes => [route('/staff' => sub ($request) {
        my $context = auth($request);
        unless ($context->user->is_authenticated) {
            my $failure = $context->failure;
            return json_response({
                error => $failure ? $failure->message : 'Basic credentials are required.',
            }, status => 401, headers => [
                'WWW-Authenticate' => www_authenticate('Basic', realm => 'staff'),
            ]);
        }
        return json_response({
            identity => $context->user->identity,
            can_read => $context->credentials->has('staff:read') ? 1 : 0,
        });
    })],
);
