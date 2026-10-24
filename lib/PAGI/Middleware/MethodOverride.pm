package PAGI::Middleware::MethodOverride;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use PAGI::Request ();
use PAGI::Utils ();
use PAGI::Utils::Middleware qw(record_receive);

=head1 NAME

PAGI::Middleware::MethodOverride - Override HTTP method from request data

=head1 SYNOPSIS

    use PAGI::Tools qw(compose middleware response route);

    my $app = compose(
        routes     => [route('/' => sub { response('Text', 'hello') })],
        middleware => [
            middleware('MethodOverride',
                param           => '_method',
                allowed_methods => [qw(PUT PATCH DELETE)],
            ),
        ],
    );

C<middleware('MethodOverride', ...)> also goes in a Router's, Mount's or
Route's C<middleware> list. It constructs the middleware and wraps the
application inside it, which you can do yourself:

    use PAGI::Middleware::MethodOverride;

    my $wrapped = PAGI::Middleware::MethodOverride->new(
        param           => '_method',
        allowed_methods => [qw(PUT PATCH DELETE)],
    )->wrap($native_app);

Without Compose, L<PAGI::Middleware::Builder> composes middleware the way
Plack::Builder does.

=head1 DESCRIPTION

PAGI::Middleware::MethodOverride allows overriding the HTTP method
using a form field, query parameter, or header. This enables HTML
forms (which only support GET and POST) to submit PUT, PATCH, and
DELETE requests.

The form field is read from a urlencoded or multipart POST body that came
without the header, as Rails (Rack) and Laravel (Symfony) read it, and
ASP.NET Core can. The application still receives that body (see
L</READING THE FORM>).

=head1 CONFIGURATION

An option not listed here dies at construction.

=over 4

=item * param (default: '_method')

Form field and query parameter name for method override.

=item * header (default: 'X-HTTP-Method-Override')

HTTP header name for method override.

=item * allowed_methods (default: [PUT, PATCH, DELETE])

Methods that can be overridden to. GET and POST are not allowed
for security reasons.

=item * check_header (default: 1)

Check the X-HTTP-Method-Override header.

=item * check_form (default: 1)

Check the C<param> field of a urlencoded or multipart POST body. C<0> never
reads the body, so a route below this middleware can stream a form; then an
override needs the header or the query parameter.

=item * check_param (default: 1)

Check the C<param> query parameter.

=item * body_buffer (default: a L<PAGI::Utils::ReceiveBuffer::TempFile>)

Where a form body this middleware reads is kept until the application
receives it: a coderef, called with the scope of each request whose body is
read, returning a buffer for that request, as for
L<PAGI::Middleware::CSRF>'s C<body_buffer>. The default holds 64KB in memory
and the rest in a temporary file.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{param} = $config->{param} // '_method';
    $self->{header} = $config->{header} // 'x-http-method-override';
    $self->{allowed_methods} = $config->{allowed_methods} // [qw(PUT PATCH DELETE)];
    $self->{check_header} = $config->{check_header} // 1;
    $self->{check_param} = $config->{check_param} // 1;
    $self->{check_form} = $config->{check_form} // 1;
    die 'MethodOverride check_form must be 0 or 1'
        unless !ref($self->{check_form}) && ($self->{check_form} eq '0' || $self->{check_form} eq '1');
    $self->{body_buffer} = $config->{body_buffer};
    die 'MethodOverride body_buffer must be a coderef that returns a buffer, like PAGI::Utils::ReceiveBuffer::TempFile->new'
        if defined($self->{body_buffer}) && ref($self->{body_buffer}) ne 'CODE';

    # Build allowed method lookup
    $self->{allowed_lookup} = { map { uc($_) => 1 } @{$self->{allowed_methods}} };
    PAGI::Utils::_reject_unknown_options('MethodOverride', $config,
        qw(allowed_methods body_buffer check_form check_header check_param header param));
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Only apply to POST requests
        if (uc($scope->{method} // '') ne 'POST') {
            await $app->($scope, $receive, $send);
            return;
        }

        my ($override_method, $downstream) = await $self->_get_override_method($scope, $receive);

        if ($override_method) {
            # Validate method is allowed
            my $upper_method = uc($override_method);
            if ($self->{allowed_lookup}{$upper_method}) {
                # Create new scope with overridden method
                my $new_scope = $self->modify_scope($scope, {
                    method => $upper_method,
                    'pagi.original_method' => $scope->{method},
                });
                await $app->($new_scope, $downstream, $send);
                return;
            }
        }

        await $app->($scope, $downstream, $send);
    };
}

# The method the request asks for, from the header, the form field or the
# query, in that order, and the receive to give the application: a form
# read here is delivered again.
async sub _get_override_method {
    my ($self, $scope, $receive) = @_;

    # Check header first (most secure)
    if ($self->{check_header}) {
        my $header_name = lc($self->{header});
        for my $h (@{$scope->{headers} // []}) {
            if (lc($h->[0]) eq $header_name) {
                return ($h->[1], $receive);
            }
        }
    }

    # Then the form field, which is what an HTML form sends
    if ($self->{check_form}) {
        (my $value, $receive) = await $self->_form_method($scope, $receive);
        return ($value, $receive) if defined($value) && length($value);
    }

    # Check query parameter
    if ($self->{check_param}) {
        my $query = $scope->{query_string} // '';
        my $param_name = $self->{param};

        # Simple query string parsing
        for my $pair (split /&/, $query) {
            my ($key, $value) = split /=/, $pair, 2;
            $key //= '';
            $value //= '';

            # URL decode
            $key =~ s/\+/ /g;
            $key =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
            $value =~ s/\+/ /g;
            $value =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;

            if ($key eq $param_name) {
                return ($value, $receive);
            }
        }
    }

    return (undef, $receive);
}

# The param field of a urlencoded or multipart body, and the receive that
# delivers that body again. The form is read through a PAGI::Request of the
# middleware's own; the application parses the replay itself. A body the
# parse rejects is no override: the application meets the same error when
# it reads the body.
async sub _form_method {
    my ($self, $scope, $receive) = @_;
    return (undef, $receive) unless PAGI::Request->new($scope, $receive)->is_form;
    my ($reading, $replaying) = record_receive($receive,
        $self->{body_buffer} ? (buffer => $self->{body_buffer}->($scope)) : ());
    my $form = await PAGI::Request->new($scope, $reading)->form_params->else(sub {
        my ($error) = @_;
        return Future->done(undef) if blessed($error) && $error->isa('PAGI::Exception::RequestBody');
        return Future->fail(@_);
    });
    return ($form ? $form->get($self->{param}) : undef, $replaying);
}

1;

__END__

=head1 HOW IT WORKS

When a POST request is received:

=over 4

=item 1. Check X-HTTP-Method-Override header (if enabled). If it is sent,
it decides, and the body is not read.

=item 2. Check the _method field of a urlencoded or multipart body (if
enabled)

=item 3. Check _method query parameter (if enabled)

=item 4. If found and method is allowed, override scope->{method}

=item 5. Original method preserved in scope->{'pagi.original_method'}

=back

A body the form parse rejects is not an override: the request stays a POST,
and the application meets the same error (a L<PAGI::Exception::RequestBody>)
when it reads the body.

=head1 READING THE FORM

A request body can be received only once, so the middleware reads the form
through L<PAGI::Utils::Middleware/record_receive> and gives the application
a receive that delivers the whole body again. The form is parsed by
L<PAGI::Request> and the parse stays in the scope, as
L<PAGI::Middleware::CSRF>'s does: the application's C<form_params>,
C<uploads> and, for a urlencoded form, C<body> return it without reading the
body again.

The cost: below this middleware a form POST can no longer be streamed.
C<body_stream> and C<multipart_stream> die "Body already consumed" for a
request whose form was read here. A route that streams form uploads sits
outside this middleware, or the middleware runs with C<< check_form => 0 >>
and the application overrides with the header or the query parameter
(C<< action="/items/7?_method=DELETE" >>). A body that is not a form (JSON,
say) is never read, and streams as usual.

=head1 SECURITY NOTES

=over 4

=item * Only POST requests can be overridden

GET requests cannot be overridden as they should be safe and idempotent.

=item * Only specific methods allowed

By default only PUT, PATCH, DELETE are allowed. GET and POST are
never allowed as override targets.

=item * Header takes precedence

The X-HTTP-Method-Override header is checked before the form field and the
query parameter, as it's harder to inject via CSRF attacks. A form that
changes the method is still a POST from the browser's point of view, so put
L<PAGI::Middleware::CSRF> on it as on any other form; the two work in
either order.

=back

=head1 HTML FORM USAGE

    <form method="POST" action="/resource/123">
        <input type="hidden" name="_method" value="DELETE">
        <button type="submit">Delete</button>
    </form>

=head1 AJAX USAGE

    fetch('/resource/123', {
        method: 'POST',
        headers: {
            'X-HTTP-Method-Override': 'DELETE'
        }
    });

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
