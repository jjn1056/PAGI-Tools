package Mini;

# Mini: a small wrap-style framework on PAGI-Tools. Handlers get a
# Mini::Request and a mutable Mini::Response; Mini's own router tries routes
# in order, and a handler may return 'next' to continue to the next match
# (the bridges Thunderhorse has).

use v5.40;
use Future::AsyncAwait;
use PAGI::Response qw(response);
use PAGI::Pages ();
use PAGI::Middleware::ErrorHandler;

# Seam (§4.3): a Request subclass adds its own fields; Tools owns only
# `scope` and `receive`.
package Mini::Request {
    use parent 'PAGI::Request';
    sub new ($class, $scope, $receive, $mini) {
        my $self = $class->SUPER::new($scope, $receive);
        $self->{mini} = $mini;
        return $self;
    }
    sub mini ($self) { $self->{mini} }
}

# Seam (§3.4): staging on an empty PAGI::Response; Mini's merge policy is
# its own -- what the handler staged wins over a class default.
package Mini::Response {
    sub new ($class) { bless { staged => PAGI::Response->new }, $class }
    sub status ($s, $c)          { $s->{staged}->status($c); $s }
    sub header ($s, $n, $v)      { $s->{staged}->header($n, $v); $s }
    sub cookie ($s, $n, $v, %o)  { $s->{staged}->cookie($n, $v, %o); $s }
    sub content_type ($s, $t)    { $s->{staged}->content_type($t); $s }
    sub text  ($s, $t) { @$s{qw(type body)} = ('Text', $t); $s }
    sub html  ($s, $h) { @$s{qw(type body)} = ('HTML', $h); $s }
    sub json  ($s, $d) { @$s{qw(type body)} = ('JSON', $d); $s }
    sub bytes ($s, $b) { @$s{qw(type body)} = ('+PAGI::Response', $b); $s }

    # One call for every outcome (§3.1-§3.3): a no-body status needs no
    # Empty, and undef content is an empty body for the base class.
    sub finalize ($s) {
        my $staged = $s->{staged};
        return PAGI::Response::response($s->{type} // '+PAGI::Response', $s->{body},
            ($staged->has_status ? (status => $staged->status) : ()),
            headers => $staged->headers);
    }
}

sub new ($class) { bless { routes => [] }, $class }

sub get ($self, $pattern, $action) {
    push @{ $self->{routes} }, [ qr/$pattern/, $action ];
    return $self;
}

sub to_app ($self) {
    my $app = async sub ($scope, $receive, $send) {
        # Not lifespan, WebSocket or SSE: dying declines them (automatic lifespan mode).
        die "Mini serves HTTP only\n" unless $scope->{type} eq 'http';
        my $req = Mini::Request->new($scope, $receive, $self);

        for my $route (@{ $self->{routes} }) {
            my ($pattern, $action) = @$route;
            next unless $scope->{path} =~ $pattern;

            # Re-dispatch, the Starlette way (§4.3): this match's parameters
            # go in the one scope, in place; the stock path_params reads them.
            $scope->{path_params} = { %+ };

            my $res = Mini::Response->new;
            my $outcome = await Future->wrap($action->($req, $res));
            next if defined $outcome && !ref $outcome && $outcome eq 'next';
            return await $res->finalize->to_app->($scope, $receive, $send);
        }

        # A page is a shareable application; response_for gives this request's
        # own value, so Mini's header can go on it (§4.1).
        my $page = PAGI::Pages->not_found(detail => 'Nothing here.');
        my $response = $page->response_for($req);
        $response->header('X-Mini' => '1');
        return await $response->to_app->($scope, $receive, $send);
    };

    # HTTP exceptions, headers included, answered by the built-in response (§4.2).
    return PAGI::Middleware::ErrorHandler->new->wrap($app);
}

1;
