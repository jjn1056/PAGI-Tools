use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';
use Scalar::Util qw(refaddr);
use PAGI::Request;

# The SUBCLASSING contract in PAGI::Request: two fields, what is parsed kept
# on the object (nothing in the scope), path_params as the router seam,
# re-dispatch through one scope.

{
    package Local::Request;
    our @ISA = ('PAGI::Request');
    sub new {
        my ($class, @args) = @_;
        my $self = $class->SUPER::new(@args);
        $self->{framework_context} = 'kept';
        return $self;
    }
    sub framework_context { $_[0]{framework_context} }
}
{
    package Local::OwnRouter;
    our @ISA = ('PAGI::Request');
    sub path_params { { id => 'from-the-framework' } }
}

sub scope_for {
    return {
        type    => 'http',
        method  => 'POST',
        path    => '/notes/1',
        headers => [ [ 'x-note' => 'a' ], [ 'content-type' => 'text/plain' ] ],
        @_,
    };
}

sub body_receive {
    my ($calls) = @_;
    return sub {
        $$calls++;
        return Future->done({ type => 'http.request', body => 'the body', more => 0 });
    };
}

subtest 'two objects over one scope each parse for themselves' => sub {
    my $calls = 0;
    my $scope = scope_for();
    my $receive = body_receive(\$calls);
    my $one = PAGI::Request->new($scope, $receive);
    my $two = PAGI::Request->new($scope, $receive);

    isnt(refaddr($one->headers), refaddr($two->headers), 'each parses the headers itself');
    is($two->header('X-Note'), 'a', 'to the same values');
    is($one->body->get, 'the body', 'the first object reads the body');
    is($two->body->get, 'the body', 'the second reads it from $receive itself');
    is($calls, 2, 'so $receive is asked twice: pass the one Request on instead');
};

subtest 'a new scope starts fresh' => sub {
    my $calls = 0;
    my $first = PAGI::Request->new(scope_for(), body_receive(\$calls));
    $first->body->get;
    my $second = PAGI::Request->new(scope_for(headers => [ [ 'x-note' => 'b' ] ]), body_receive(\$calls));
    is($second->header('X-Note'), 'b', 'its own headers');
    is($second->body->get, 'the body', 'its own body');
    is($calls, 2, 'received again');
};

subtest "a subclass's own field survives" => sub {
    my $request = Local::Request->new(scope_for(), body_receive(\my $calls));
    $request->headers;
    $request->body->get;
    is($request->framework_context, 'kept', 'after parsing headers and reading the body');
};

subtest 'an overridden path_params is what path_param reads' => sub {
    my $request = Local::OwnRouter->new(scope_for(path_params => { id => 'from-the-scope' }), sub { });
    is($request->path_param('id'), 'from-the-framework', 'path_param');
    like(dies { $request->path_param('missing', strict => 1) }, qr/path_param 'missing' not found/,
        'strict mode reads it too');
};

subtest 're-dispatch through one scope' => sub {
    # A framework router passing one request through several matches writes
    # each match's parameters into the scope in place; the stock path_params
    # reads the scope live, so one object sees every match.
    my $scope = scope_for();
    my $request = PAGI::Request->new($scope, sub { });
    my @seen;
    for my $match ({ tenant => 'acme' }, { tenant => 'acme', id => 7 }) {
        $scope->{path_params} = $match;
        push @seen, { %{ $request->path_params } };
    }
    is(\@seen, [ { tenant => 'acme' }, { tenant => 'acme', id => 7 } ], 'each match is seen');
    is($request->path_param('id'), 7, 'path_param reads the last match');
};

done_testing;
