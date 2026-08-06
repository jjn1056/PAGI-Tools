package MyApp::URL;

use strict;
use warnings;
use Carp qw(croak);

sub _id {
    my ($label, $value) = @_;
    croak "$label must be a decimal identifier"
        unless defined $value
            && !ref($value)
            && $value =~ /\A\d+\z/;
    return "$value";
}

sub people {
    return '/person';
}

sub person {
    my ($class, $person_id) = @_;
    $person_id = _id('person_id', $person_id);
    return "/person/$person_id";
}

sub blogs {
    my ($class, $person_id) = @_;
    $person_id = _id('person_id', $person_id);
    return "/person/$person_id/blog";
}

sub blog {
    my ($class, $person_id, $blog_id) = @_;
    $person_id = _id('person_id', $person_id);
    $blog_id = _id('blog_id', $blog_id);
    return "/person/$person_id/blog/$blog_id";
}

1;
