package PAGI::Middleware::Stash;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use PAGI::Utils ();

=head1 NAME

PAGI::Middleware::Stash - One shared stash for everything below it

=head1 SYNOPSIS

    use PAGI::Tools qw(compose middleware response route stash);

    my $app = compose(
        routes     => [route('/' => sub {
            my ($req) = @_;
            stash($req)->set(user => 'alice');
            response('Text', 'hello');
        })],
        middleware => [
            middleware('Stash'),
            middleware(\&log_user),   # reads stash($scope)->get('user') after its app returns
        ],
    );

C<middleware('Stash')> also goes in a Router's, Mount's or Route's
C<middleware> list. It constructs the middleware and wraps the application
inside it, which you can do yourself:

    use PAGI::Middleware::Stash;

    my $wrapped = PAGI::Middleware::Stash->new->wrap($native_app);

=head1 DESCRIPTION

PAGI::Middleware::Stash puts an empty L<PAGI::Stash> on the scope it hands
its application, so every layer below it shares one stash: a value a handler
stores is seen by each middleware between this one and the handler,
including after the handler returns.

Without it there is no stash, and L<PAGI::Stash> dies: stack this
middleware above every layer that uses the stash. It is one stash for the
request because it is created once, above them: middleware hand their
applications copies of the scope, and a stash created wherever it was first
used would, below a copy, be held only by that copy.

The stash goes on the copy this middleware passes on, so layers above it do
not see it: it is shared below wherever it is stacked. A scope that already
carries a stash keeps it, so two of these middleware, or one inside a stash
created earlier, share that one. Each HTTP request, WebSocket connection and
SSE stream gets its own; a lifespan scope is passed on unchanged.

=head1 CONFIGURATION

None. An option dies at construction.

=cut

sub _init {
    my ($self, $config) = @_;
    PAGI::Utils::_reject_unknown_options('Stash', $config);
}

sub wrap {
    my ($self, $app) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        return await $app->($scope, $receive, $send)
            if $scope->{type} eq 'lifespan' || ref $scope->{'pagi.stash'} eq 'HASH';

        await $app->($self->modify_scope($scope, { 'pagi.stash' => {} }), $receive, $send);
    };
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Stash> - the stash's accessors

L<PAGI::Middleware> - Base class for middleware, and why it copies the scope

=cut
