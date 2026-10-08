package PAGI::ResponseBuilder;

use strict;
use warnings;

use Carp qw(croak);
use PAGI::Headers;
# Not imported: this class's own response() method would replace it.
use PAGI::Response ();

# All state lives under one key, so a subclass's own keys (including Moo and
# Mooish attributes) cannot collide with it.
sub new {
    my ($class, @arguments) = @_;
    croak 'PAGI::ResponseBuilder->new takes no arguments' if @arguments;
    return bless { _response_builder => { headers => PAGI::Headers->new } }, $class;
}

sub _state { $_[0]->{_response_builder} }

sub _require_name {
    my ($name) = @_;
    croak 'Header name is required' unless defined $name && !ref($name) && length $name;
    return;
}

sub _is_content_type { lc($_[0]) eq 'content-type' }

# --- status ---

sub status {
    my ($self, @code) = @_;
    my $state = $self->_state;
    unless (@code) {
        return $state->{value}->status if $state->{value};
        return $state->{status} // 200;
    }
    my ($code) = @code;
    if ($state->{value}) {
        $state->{value}->status($code);
    } else {
        PAGI::Response::_validate_status($code);
    }
    $state->{status} = $code;
    return $self;
}

sub status_try {
    my ($self, $code) = @_;
    return $self if $self->has_status;
    return $self->status($code);
}

sub has_status {
    my ($self) = @_;
    my $state = $self->_state;
    return 1 if defined $state->{status};
    return $state->{value} && $state->{value}->has_status ? 1 : 0;
}

# --- headers ---

sub header {
    my ($self, $name, @value) = @_;
    _require_name($name);
    my $state = $self->_state;
    unless (@value) {
        return $self->content_type if _is_content_type($name);
        return $state->{value}->header($name) if $state->{value};
        return $state->{headers}->get($name);
    }
    my ($value) = @value;
    # Checked before the Content-Type alias, so undef is refused for every
    # field; clearing the type is content_type(undef) or remove_header.
    croak 'Header value is required' unless defined $value && !ref($value);
    return $self->content_type($value) if _is_content_type($name);
    $state->{value}->header($name, $value) if $state->{value};
    $state->{headers}->add($name, $value);
    return $self;
}

sub header_all {
    my ($self, $name) = @_;
    _require_name($name);
    my $state = $self->_state;
    return $state->{value}->header_all($name) if $state->{value};
    if (_is_content_type($name)) {
        return [ defined $state->{content_type} ? $state->{content_type} : () ];
    }
    return [ $state->{headers}->get_all($name) ];
}

sub has_header {
    my ($self, $name) = @_;
    return 0 unless defined $name && !ref($name) && length $name;
    my $state = $self->_state;
    return $state->{value}->has_header($name) ? 1 : 0 if $state->{value};
    return defined $state->{content_type} ? 1 : 0 if _is_content_type($name);
    return $state->{headers}->has($name) ? 1 : 0;
}

sub header_try {
    my ($self, $name, $value) = @_;
    return $self if $self->has_header($name);
    return $self->header($name, $value);
}

sub remove_header {
    my ($self, $name) = @_;
    _require_name($name);
    return $self->content_type(undef) if _is_content_type($name);
    my $state = $self->_state;
    $state->{value}->remove_header($name) if $state->{value};
    $state->{headers}->remove($name);
    return $self;
}

# --- content type ---

sub content_type {
    my ($self, @type) = @_;
    my $state = $self->_state;
    unless (@type) {
        return $state->{value}->content_type if $state->{value};
        return $state->{content_type};
    }
    my ($type) = @type;
    croak 'Content-Type must be a scalar' if ref $type;
    if (my $value = $state->{value}) {
        $value->content_type(defined $type
            ? _with_charset($value, $type)
            : $value->default_content_type);
    }
    if (defined $type) {
        $state->{content_type} = $type;
    } else {
        delete $state->{content_type};
    }
    return $self;
}

sub content_type_try {
    my ($self, $type) = @_;
    return $self if $self->has_content_type;
    return $self->content_type($type);
}

sub has_content_type { $_[0]->has_header('Content-Type') }

# Text and HTML bodies are always UTF-8, so a custom type without a charset
# says so. JSON is UTF-8 by definition and takes no charset parameter.
sub _with_charset {
    my ($value, $type) = @_;
    return $type
        unless $value->isa('PAGI::Response::Text') || $value->isa('PAGI::Response::HTML');
    return $type if $type =~ /charset=/i;
    my ($media) = $type =~ m{\A\s*([^;\s]+)};
    return $type
        if defined $media && (lc($media) eq 'application/json' || $media =~ m{\+json\z}i);
    return "$type; charset=utf-8";
}

# --- cookies are Set-Cookie headers ---

sub cookie {
    my ($self, $name, $value, %options) = @_;
    return $self->header('Set-Cookie',
        PAGI::Response::_set_cookie_value($name, $value, %options));
}

sub delete_cookie {
    my ($self, $name, %options) = @_;
    return $self->cookie($name, '', %options, max_age => 0, expires => 0);
}

# --- choosing the body ---

sub as {
    my ($self, $name, @arguments) = @_;
    croak 'as() requires a Response class name and a value' unless @arguments;
    my ($value, @options) = @arguments;
    croak 'as() class options must be name/value pairs' if @options % 2;
    for (my $index = 0; $index < @options; $index += 2) {
        my $option = $options[$index];
        croak "as() takes no '$option' option: set it on the builder"
            if defined $option && grep { $option eq $_ } qw(status headers content_type);
    }
    return $self->_build($name, $value, \@options, undef);
}

sub text {
    my ($self, @arguments) = @_;
    croak 'text() takes one argument' unless @arguments == 1;
    return $self->as('Text', $arguments[0]);
}

sub html {
    my ($self, @arguments) = @_;
    croak 'html() takes one argument' unless @arguments == 1;
    return $self->as('HTML', $arguments[0]);
}

sub json {
    my ($self, @arguments) = @_;
    croak 'json() takes one argument' unless @arguments == 1;
    return $self->as('JSON', $arguments[0]);
}

sub redirect {
    my ($self, $url, @status) = @_;
    croak 'redirect() takes a URL and an optional status' unless @_ >= 2 && @status <= 1;
    return $self->_build('Redirect', $url, [], $status[0] // 302);
}

sub file {
    my ($self, $path, @options) = @_;
    return $self->as('File', $path, @options);
}

sub stream {
    my ($self, $producer, @options) = @_;
    return $self->as('Stream', $producer, @options);
}

sub empty {
    my ($self, @arguments) = @_;
    croak 'empty() takes no arguments' if @arguments;
    $self->_state->{value} = $self->_empty_value;
    return $self;
}

sub has_body_source { $_[0]->_state->{value} ? 1 : 0 }

# Build from the collected state; commit only once construction succeeded, so
# a failure leaves the builder as it was. A status the body brings with it
# (a redirect's) belongs to the value, not to the collected state.
sub _build {
    my ($self, $name, $input, $options, $own_status) = @_;
    my $state = $self->_state;
    my @pairs = @$options;
    my $status = defined $own_status ? $own_status : $state->{status};
    push @pairs, status => $status if defined $status;
    my @headers = $state->{headers}->flatten;
    push @pairs, headers => \@headers if @headers;
    push @pairs, content_type => $state->{content_type} if defined $state->{content_type};
    my $value = PAGI::Response::response($name, $input, @pairs);
    if (defined $state->{content_type}) {
        my $type = _with_charset($value, $state->{content_type});
        $value->content_type($type) if $type ne $state->{content_type};
    }
    $state->{value} = $value;
    return $self;
}

# An empty response states its status and carries no Content-Type.
sub _empty_value {
    my ($self) = @_;
    my $state = $self->_state;
    my @headers = $state->{headers}->flatten;
    return PAGI::Response::response('Empty',
        status => $state->{status} // 200,
        (@headers ? (headers => \@headers) : ()));
}

# --- finishing ---

sub response {
    my ($self) = @_;
    return $self->_state->{value} // $self->_empty_value;
}

sub to_app { $_[0]->response->to_app }

1;

__END__

=head1 NAME

PAGI::ResponseBuilder - Collect a response in stages, for frameworks

=head1 SYNOPSIS

    package My::Framework::Response;
    use parent 'PAGI::ResponseBuilder';

    # in the framework, while handling a request
    my $res = My::Framework::Response->new;
    $res->header('X-Request-Id' => $id);          # a before-hook
    $res->cookie(session => $sid, httponly => 1); # session code
    $res->status(201)->json($item);               # the handler
    $res->header('X-Elapsed' => $ms);             # an after-hook

    await $res->to_app->($scope, $receive, $send);

=head1 DESCRIPTION

A framework that handles a request in stages collects the response the same
way: before-hooks, authentication and session code add headers and cookies,
the handler chooses the body, and after-hooks may add more.
PAGI::ResponseBuilder is that collector, for frameworks to extend. Every
response it holds is an ordinary L<PAGI::Response> value made by
L<PAGI::Response/response>.

Applications do not need it: they return a complete value from
C<response('Name', ...)>.

The builder holds no scope and never sends. L</to_app> returns the current
value's application, and sending it is the framework's job.

=head1 STATE AND TRANSITIONS

The builder keeps a collected status, an ordered list of collected headers
(cookies included), a collected Content-Type, and the current value, once a
body method has succeeded. It never keeps a body's input.

=over 4

=item * B<Body methods> build a new value from the collected state and their
own arguments, and replace the current value only when that succeeds. A
failure leaves the builder exactly as it was. The old value is never asked to
change, so a redirect can replace a redirect, and a Problem a redirect.

=item * B<Setters> (C<status>, C<header>, C<remove_header>, C<content_type>,
C<cookie>) apply to the current value first, then to the collected state.
A change the value refuses (a status that forbids its body, a redirect's own
status or Location) croaks and changes nothing.

=item * B<A status a body brings with it> belongs to that value, not to the
collected state: C<redirect('/x')> then C<text('hi')> is a 200.

=item * B<Cookies are headers.> C<cookie> adds a C<Set-Cookie> field, so
order, reading and removal follow the header list.

=item * B<Clearing the Content-Type> means the body class's default, whether
it is cleared before or after the body.

=item * B<Reads> come from the current value when there is one, else from
the collected state.

=back

Changing the value L</response> returns directly is not supported: such
changes are not part of the collected state, and a later body method replaces
the value.

=head1 ERROR TIMING

=over 4

=item * B<Construction errors> (a status the class forbids or owns,
unencodable JSON, a non-string Text body, a bad redirect target, an unknown
class) are raised by the method that caused them.

=item * B<Delivery errors before the response starts> are raised while the
application from L</to_app> runs, before it sends C<http.response.start>: a
File's existence, readability and range planning. Nothing has been sent, so a
framework may catch them and send another response.

=item * B<Failures after the response has started> cannot be answered with
another response; rethrow them. A Stream sends its start before it calls its
producer, so a producer's failure is always one of these.
C<pagi.connection>'s C<response_started> tells the two cases apart.

=back

=head1 CONSTRUCTOR

=head2 new

    my $builder = PAGI::ResponseBuilder->new;

Takes no arguments. A subclass built with Moo passes none from
C<FOREIGNBUILDARGS>. Builder state lives under the C<_response_builder> key of
the blessed hash.

=head1 COLLECTING

Each setter returns the builder.

=head2 status

    $builder->status(201);
    my $code = $builder->status;

Sets the status, or reads it: the current value's status, else the collected
status, else 200. An invalid status croaks when it is set.

=head2 status_try

Sets the status unless L</has_status>.

=head2 has_status

True when a status was collected, or the current value has one (a Redirect
or Problem does).

=head2 header

    $builder->header('X-Example' => 'one');
    my $value = $builder->header('X-Example');

Adds a header field, or reads one as L<PAGI::Response/header> does. The
value must be a defined string, for every field. A C<Content-Type> name with
a defined value means L</content_type>; clear the type with
C<content_type(undef)> or L</remove_header>.

=head2 header_all

Every value of a field, as an arrayref.

=head2 has_header

True when the field is present: on the current value if there is one, else
in the collected headers.

=head2 header_try

Adds the field unless it is present.

=head2 remove_header

Removes every value of a field. A C<Content-Type> name means
C<content_type(undef)>.

=head2 content_type

    $builder->content_type('text/csv');
    $builder->content_type(undef);

Sets, clears or reads the Content-Type. Clearing means the body class's
default. For a Text or HTML body, a type without a charset gets
C<; charset=utf-8>, except JSON types (C<application/json>, C<*+json>).

=head2 content_type_try

Sets the Content-Type unless one is present. After a body, the class's
default counts as present, so C<< text('x')->content_type_try('text/csv') >>
keeps C<text/plain; charset=utf-8>.

=head2 has_content_type

True when a Content-Type is present: on the current value if there is one,
else collected.

=head2 cookie

    $builder->cookie(session => $id, httponly => 1, samesite => 'Lax');

Adds a C<Set-Cookie> field. The options are those of
L<PAGI::Response/cookie>.

=head2 delete_cookie

Adds a C<Set-Cookie> field that expires the cookie.

=head1 CHOOSING THE BODY

Each method builds the value now and returns the builder.

=head2 as

    $builder->as('JSON', $data);
    $builder->as('+My::Response', $value);
    $builder->as('File', $path, filename => 'report.pdf');

Builds C<response($name, $value, ...)> with the collected state. C<$name>
resolves as in L<PAGI::Response/response>. Trailing options are the class's
own; C<status>, C<headers> and C<content_type> croak, since the builder owns
them.

=head2 text

    $builder->text($string);

C<as('Text', $string)>. The string must be defined and not a reference; a
framework that renders other values stringifies them first, in its own
override.

=head2 html

    $builder->html($string);

C<as('HTML', $string)>, with the same rule for the string as L</text>.

=head2 json

    $builder->json($data);

C<as('JSON', $data)>. Data that cannot be encoded croaks here.

=head2 redirect

    $builder->redirect('/login');
    $builder->redirect('/moved', 301);

A Redirect with the given status (default 302), which belongs to the value
rather than the collected state.

=head2 file

    $builder->file($path, filename => 'report.pdf');

C<as('File', $path, @options)>. The file is checked when the response is
sent, not here (see L</ERROR TIMING>).

=head2 stream

    $builder->stream(async sub { my ($writer) = @_; await $writer->write($chunk) });

C<as('Stream', $producer, @options)>. The producer runs after the response
has started.

=head2 empty

An Empty response with the collected status, or 200, and no Content-Type.

=head2 has_body_source

True once a body method has succeeded.

=head1 FINISHING

=head2 response

The current value. With no body chosen, a new Empty value (as L</empty>
builds) each time it is called.

=head2 to_app

    await $builder->to_app->($scope, $receive, $send);

The current value's application.

=head1 SUBCLASSING

Frameworks extend this class. A subclass may rely on the following.

=over 4

=item * Builder state lives under the C<_response_builder> key of the
blessed hash, so a subclass's own keys, including Moo and Mooish attributes,
do not collide with it. There is no C<BUILD> or C<DEMOLISH> logic, and the
builder holds no scope, connection or sender.

=item * L</new> takes no arguments; a Moo subclass's C<FOREIGNBUILDARGS>
returns an empty list.

=item * Every public method is an ordinary method that a subclass may
override and call with C<SUPER::>. Coercing input before the builder sees it
(a framework that renders exception objects stringifies them in its C<text>)
is the intended pattern.

=item * Some methods call others through C<$self>, so an override sees those
calls too:

=over 4

=item * C<text>, C<html>, C<json>, C<file> and C<stream> call L</as>.
C<redirect> and C<empty> build directly and do not.

=item * C<cookie>, C<delete_cookie> and C<header_try> call L</header>.

=item * C<header> and C<remove_header> with a C<Content-Type> name, and
C<content_type_try>, call L</content_type>; C<status_try> calls L</status>.

=item * C<to_app> calls L</response>.

=back

An override of L</as> must not call back into the shorthands (C<text> and
the others): they call C<as>, so the two would recurse.

=back

=head1 SEE ALSO

L<PAGI::Response>, L<PAGI::Response/response>

=cut
