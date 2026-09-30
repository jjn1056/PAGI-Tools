package NotesDemo::Library;
use v5.40;
use Future;

sub new ($class) {
    return bless { notes => [
        {id => 1, author_id => 'alice', text => 'All notes in this demo are public.'},
    ] }, $class;
}

sub all_published ($self) {
    return Future->done([map { +{%$_} } @{$self->{notes}}]);
}

sub publish ($self, $author, $data) {
    my $note = {
        id => 1 + @{$self->{notes}},
        author_id => $author,
        text => $data->{text},
    };
    push @{$self->{notes}}, $note;
    return Future->done({%$note});
}

1;
