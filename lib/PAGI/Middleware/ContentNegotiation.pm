package PAGI::Middleware::ContentNegotiation;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future;
use Future::AsyncAwait;
use PAGI::Response::Text ();
use PAGI::ContentNegotiation;
use PAGI::HTTPConnection ();
use PAGI::Utils ();
use PAGI::Utils::Middleware ();

=head1 NAME

PAGI::Middleware::ContentNegotiation - HTTP content negotiation middleware

=head1 SYNOPSIS

    use PAGI::Tools qw(compose middleware negotiated_type response route);

    # An API that only speaks JSON: anything else is refused with a 406
    # before a handler runs.
    my $app = compose(
        routes     => [route('/items' => sub { response('JSON', { items => [] }) })],
        middleware => [
            middleware('ContentNegotiation', supported_types => ['application/json']),
        ],
    );

With more than one representation, handlers read the choice with
L<PAGI::ContentNegotiation> (C<negotiated_type>, C<respond_to>); C<refuse>
replaces the stock 406:

    # Two representations; handlers ask PAGI::ContentNegotiation for the choice.
    middleware('ContentNegotiation', supported_types => ['json', 'html'])

    async sub show ($request) {
        return negotiated_type($request) eq 'html' ? response('HTML', render($item))
                                                   : response('JSON', $item);
    }

    # Refuse your own way
    middleware('ContentNegotiation', supported_types => ['application/json'],
        refuse => response('JSON', { detail => 'This API only speaks JSON' }, status => 406))

C<middleware('ContentNegotiation', ...)> also goes in a Router's, Mount's or
Route's C<middleware> list. It constructs the middleware and wraps the
application inside it, which you can do yourself:

    use PAGI::Middleware::ContentNegotiation;

    my $wrapped = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json'],
    )->wrap($native_app);

Without Compose, L<PAGI::Middleware::Builder> composes middleware the way
Plack::Builder does.

=head1 DESCRIPTION

PAGI::Middleware::ContentNegotiation picks the best of C<supported_types>
for the request's C<Accept> header, using the shared
L<PAGI::ContentNegotiation> rules, and puts it in the scope for the wrapped
application, where L<PAGI::ContentNegotiation>'s C<respond_to> and
C<negotiated_type> read it. A request without C<Accept> accepts anything and gets the first
supported type, so the order of C<supported_types> is the default.

A request that accepts none of them is refused with C<406 text/plain>,
C<Not Acceptable. Supported types: ...> -- the list RFC 9110 suggests a 406
carry -- and the wrapped application does not run. C<refuse> replaces the
refusal, or with C<0> lets the application decide.

Every HTTP answer that passes through it carries C<Vary: Accept>: the
application's, the stock 406, a C<refuse> replacement, and with
C<refuse =E<gt> 0> the application's answer to an unacceptable request. The
field is merged into any C<Vary> the response already has (C<*> stays C<*>),
so a shared cache keeps the representations apart.

A response thrown with C<die response('JSON', ...)>, and a 500 from a bug, are sent
by Compose's error handler, which sits outside declared middleware, so they
carry no C<Vary> from here. That is right for a fixed answer; a handler that
picks an error's representation by the negotiated type returns it instead.

Where you declare it is the part of the application that negotiates. In
Compose's or a Router's C<middleware> list it covers every route below,
so a route that answers in one type only (a health check) also gets C<Vary>
and can be refused; declare it on a C<mount> or on the routes that
negotiate instead.

To negotiate inside one handler without a middleware, use
L<PAGI::Request/preferred_type>.

=head1 CONFIGURATION

An option not listed here dies at construction.

=over 4

=item * supported_types (required)

Array of MIME types this part of the application can produce, most preferred
first. Each entry is a media type (C<type/subtype>) or a shortcut
L<PAGI::ContentNegotiation> knows (C<json>, C<html>, ...); anything else
dies when the middleware is built, as does an empty list.

=item * refuse (default: a 406 text response)

An application that answers an unmatched request instead of the plain-text
default: a Request handler (a coderef called with one
L<PAGI::Request>, returning a Response or an application) or an object
with C<to_app>, which includes every L<PAGI::Response>. It receives the scope with
the C<pagi.content_negotiation> record (its C<accepted> entry is the parsed
Accept header).

Exactly C<0>: the middleware never refuses. An unmatched request reaches the
application with no negotiated type (C<negotiated_type> returns undef), and
choosing a fallback is the application's call:

    my $type = negotiated_type($request) // 'json';

Any other plain value dies. C<strict> and C<default_type> were removed:
refusing is the default, and C<refuse =E<gt> 0> replaces C<strict =E<gt> 0>;
passing either dies.

A native C<($scope, $receive, $send)> application is passed as
C<as_app_object($app)>. Objects -- every Response and L<PAGI::Pages> value --
mean the same in every slot, and are the portable form for anything also
given to middleware outside PAGI-Tools.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    die "ContentNegotiation 'strict' was removed: it refuses an unmatched request by default; refuse => 0 lets the application decide"
        if exists $config->{strict};
    die "ContentNegotiation 'default_type' was removed: a request without Accept gets the first supported type; with refuse => 0 an unmatched request has no preferred type"
        if exists $config->{default_type};

    my $supported_types = $config->{supported_types}
        // die "ContentNegotiation requires 'supported_types' option";
    die 'ContentNegotiation: supported_types must be an arrayref'
        unless ref($supported_types) eq 'ARRAY';
    die 'ContentNegotiation: supported_types must list at least one type'
        unless @$supported_types;
    for my $type (@$supported_types) {
        next if PAGI::ContentNegotiation->is_known_type($type);
        my $shown = defined $type ? "'$type'" : 'undef';
        die "ContentNegotiation: unknown type $shown in supported_types; use a media type (type/subtype) or a shortcut: "
            . join(', ', PAGI::ContentNegotiation->shortcuts);
    }
    $self->{supported_types} = [ @$supported_types ];

    # Absent: a plain-text 406 listing the supported types, as RFC 9110
    # suggests. Exactly 0: the application decides.
    my $refuse = PAGI::Utils::_refuse_option('ContentNegotiation', $config, 1);
    my $supported = join(', ',
        map { PAGI::ContentNegotiation->normalize_type($_) } @{$self->{supported_types}});
    $self->{refuse} = !defined($refuse) ? PAGI::Response::Text->new(
            "Not Acceptable. Supported types: $supported", status => 406,
        )->to_app
        : ref($refuse) ? $refuse
        : undef;
    PAGI::Utils::_reject_unknown_options('ContentNegotiation', $config,
        qw(refuse supported_types));
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Accept, every field joined
        my $accept = PAGI::HTTPConnection->new($scope)->header('accept') // '*/*';
        my $preferred = PAGI::ContentNegotiation->best_match(
            $self->{supported_types}, $accept,
        );

        # The preferred type is undef when nothing matched.
        my @accepted = $self->_parse_accept($accept);
        my $new_scope = $self->modify_scope($scope, {
            'pagi.content_negotiation' => {
                type      => $preferred,
                supported => [ @{$self->{supported_types}} ],
                refusing  => $self->{refuse} ? 1 : 0,
                accepted  => \@accepted,
            },
        });

        # Every answer from here depends on Accept, the refusal included. The
        # header goes on a copy: the response's own list belongs to whoever
        # built it, who may send it again.
        my $vary_send = PAGI::Utils::Middleware::wrap_response_headers($send, sub {
            $_[0]->add_vary('Accept');
        });
        my $target = !defined($preferred) && $self->{refuse} ? $self->{refuse} : $app;
        await $target->($new_scope, $receive, $vary_send);
    };
}

sub _parse_accept {
    my ($self, $accept) = @_;

    return map {
        +{ type => $_->[0], q => $_->[1] }
    } PAGI::ContentNegotiation->parse_accept($accept);
}

1;

__END__

=head1 SCOPE EXTENSIONS

This middleware adds the following to $scope:

=over 4

=item * pagi.content_negotiation

A hashref: C<type>, the chosen entry of C<supported_types> as written (undef
when nothing was acceptable, which is reachable only with
C<refuse =E<gt> 0>); C<supported>, a copy of C<supported_types>; C<refusing>,
1 unless C<refuse =E<gt> 0>; and C<accepted>, the parsed Accept header as
C<< { type => $type, q => $quality } >> entries in the shared preference
order. Read it with L<PAGI::ContentNegotiation>. A nested ContentNegotiation
replaces the record for the part of the application it wraps.

=back

=head1 ACCEPT HEADER PARSING

The Accept header is parsed by L<PAGI::ContentNegotiation>:

    Accept: text/html, application/json;q=0.9, */*;q=0.1

Each entry retains the existing C<< { type => $type, q => $quality } >> shape
and shared preference order. Higher quality values (q) indicate higher
preference. The default is q=1.0.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::ContentNegotiation> - Shared Accept matching

=cut
