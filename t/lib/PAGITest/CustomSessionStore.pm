package PAGITest::CustomSessionStore;

# A session store outside the PAGI::Middleware::Session::Store namespace,
# for session_store('+PAGITest::CustomSessionStore', ...).

use strict;
use warnings;
use parent 'PAGI::Middleware::Session::Store';
use Future;

sub new {
    my ($class, %args) = @_;
    return bless { %args, sessions => {} }, $class;
}

sub get    { my ($self, $id) = @_; return Future->done($self->{sessions}{$id}) }
sub set    { my ($self, $id, $data) = @_; $self->{sessions}{$id} = $data; return Future->done($id) }
sub delete { my ($self, $id) = @_; delete $self->{sessions}{$id}; return Future->done }

1;
