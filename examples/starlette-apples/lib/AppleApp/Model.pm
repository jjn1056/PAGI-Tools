package AppleApp::Model;

use v5.40;

use Exporter qw(import);
use List::Util qw(max);
use Moose;
use Types::Standard qw(HashRef);

our @EXPORT_OK = qw(apple_model);

has _apples => (
    traits  => ['Hash'],
    is      => 'ro',
    isa     => HashRef[HashRef],
    default => sub {
        return {
            1 => { id => 1, name => 'Gala',       color => 'Red/Yellow' },
            2 => { id => 2, name => 'Honeycrisp', color => 'Rosy Red' },
        };
    },
    handles => {
        _apple        => 'get',
        _store_apple  => 'set',
        _delete_apple => 'delete',
        _apple_ids    => 'keys',
    },
);

sub all($self) {
    return [
        map { $self->_apple($_) }
        sort { $a <=> $b } $self->_apple_ids
    ];
}

sub find($self, $id) {
    return $self->_apple($id);
}

sub create($self, $data) {
    my $id = max(0, $self->_apple_ids) + 1;
    my $apple = { %$data, id => $id };
    $self->_store_apple($id, $apple);
    return $apple;
}

sub update($self, $id, $data) {
    my $apple = $self->_apple($id) or return undef;
    my $updated = { %$apple, %$data, id => $id };
    $self->_store_apple($id, $updated);
    return $updated;
}

sub delete($self, $id) {
    return $self->_delete_apple($id);
}

sub apple_model() {
    return __PACKAGE__->new;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
