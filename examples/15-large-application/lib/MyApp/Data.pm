package MyApp::Data;

use v5.40;

my $PEOPLE = [
    {
        id      => '1',
        name    => 'Ada Lovelace',
        summary => 'Mathematician and writer',
    },
    {
        id      => '2',
        name    => 'Grace Hopper',
        summary => 'Computer scientist and naval officer',
    },
    {
        id      => '3',
        name    => 'Margaret Hamilton',
        summary => 'Software engineer',
    },
];

my $BLOGS = {
    '1' => [
        {
            id        => '101',
            person_id => '1',
            title     => 'Notes on the Analytical Engine',
            body      => 'A machine may compose elaborate and scientific pieces of music.',
        },
        {
            id        => '102',
            person_id => '1',
            title     => 'Poetical Science',
            body      => 'Imagination helps us discover what computation can express.',
        },
    ],
    '2' => [
        {
            id        => '201',
            person_id => '2',
            title     => 'Compilers and Clear Languages',
            body      => 'Programming languages should help people state ideas clearly.',
        },
    ],
    '3' => [],
};

sub new($class) {
    my %people = map { $_->{id} => +{%$_} } @$PEOPLE;
    my %blogs = map {
        my $person_id = $_;
        $person_id => [map { +{%$_} } @{$BLOGS->{$person_id}}];
    } keys %$BLOGS;

    return bless {
        people       => \%people,
        people_order => [map { $_->{id} } @$PEOPLE],
        blogs        => \%blogs,
    }, $class;
}

sub people($self) {
    return [
        map { +{%{$self->{people}{$_}}} }
        @{$self->{people_order}}
    ];
}

sub person($self, $person_id) {
    my $person = $self->{people}{$person_id};
    return defined $person ? +{%$person} : undef;
}

sub blogs_for($self, $person_id) {
    return undef unless exists $self->{people}{$person_id};
    my $blogs = $self->{blogs}{$person_id} || [];
    return [map { +{%$_} } @$blogs];
}

sub blog($self, $person_id, $blog_id) {
    return undef unless exists $self->{people}{$person_id};
    my ($blog) = grep {
        $_->{id} eq $blog_id
    } @{$self->{blogs}{$person_id} || []};
    return defined $blog ? +{%$blog} : undef;
}

1;
