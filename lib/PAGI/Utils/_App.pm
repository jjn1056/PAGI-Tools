package PAGI::Utils::_App;

use strict;
use warnings;

sub new {
    my ($class, $app) = @_;
    return bless { app => $app }, $class;
}

sub to_app {
    return $_[0]->{app};
}

1;
