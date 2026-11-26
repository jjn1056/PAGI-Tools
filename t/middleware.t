use v5.24;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Test::Client;

use PAGI::Middleware;

# An app that answers with the scope's tag, and records the scope it saw.
my $seen;
my $inner = async sub {
    my ($scope, $receive, $send) = @_;
    $seen = $scope;
    await $send->({ type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain']] });
    await $send->({ type => 'http.response.body', body => $scope->{tag} // 'none', more => 0 });
};

package Local::Tag {
    use parent -norequire, 'PAGI::Middleware';
    use Class::Tiny qw(tag);
    use Future::AsyncAwait;

    async sub call {
        my ($self, $scope, $receive, $send) = @_;
        await $self->app->({ %$scope, tag => $self->tag }, $receive, $send);
    }
}

package Local::Provider {
    use parent -norequire, 'PAGI::App';
    sub call { my ($self, @args) = @_; return $inner->(@args) }
}

# A subclass in main's style: wrap overridden to return its own closure.
package Local::Closure {
    use parent -norequire, 'PAGI::Middleware';
    use Future::AsyncAwait;

    sub wrap {
        my ($self, $app) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            await $app->({ %$scope, tag => 'closure' }, $receive, $send);
        };
    }
}

sub get { PAGI::Test::Client->new(app => $_[0])->get('/')->content }

subtest 'wrap on the class: options after the app, a code reference back' => sub {
    my $app = Local::Tag->wrap($inner, tag => 'a');
    is ref $app, 'CODE', 'a code reference';
    is get($app), 'a', 'the middleware ran, with its option';
};

subtest 'wrap on an instance: main\'s call sites' => sub {
    is get(Local::Tag->new(tag => 'b')->wrap($inner)), 'b', 'new(%options)->wrap($app)';
};

subtest 'an application provider is wrapped like a code reference' => sub {
    my $middleware = Local::Tag->new(tag => 'c');
    is get($middleware->wrap(Local::Provider->new)), 'c', 'an object with to_app';
    is ref $middleware->app, 'CODE', 'app is always the code reference';
};

subtest 'app given to new is a code reference too' => sub {
    my $middleware = Local::Tag->new(app => Local::Provider->new, tag => 'e');
    is ref $middleware->app, 'CODE', 'a provider given to new';
    is get($middleware->to_app), 'e', 'and it runs';
    like dies { Local::Tag->new(app => [], tag => 'x') },
        qr/\Awrap takes an application: a code reference or an object with to_app/, 'new refuses the same';
};

subtest 'wrap refuses what is not an application' => sub {
    for my $value ([], undef, {}, 'a string') {
        like dies { Local::Tag->wrap($value, tag => 'x') },
            qr/\Awrap takes an application: a code reference or an object with to_app/,
            defined $value ? (ref $value || 'a string') : 'undef';
    }
};

subtest 'the inner app gets a copy of the scope' => sub {
    my $client = PAGI::Test::Client->new(app => Local::Tag->wrap($inner, tag => 'd'));
    $client->get('/');
    is $seen->{tag}, 'd', 'the inner app sees the tag';
};

subtest 'a subclass overriding wrap still works' => sub {
    is get(Local::Closure->new->wrap($inner)), 'closure', "its own closure";
};

done_testing;
