package PAGI::Utils::_App;

use strict;
use warnings;

sub new {
    my ($class, $app) = @_;
    my $self = bless \$app, $class;
    Internals::SvREADONLY($$self, 1);
    return $self;
}

sub to_app {
    return ${$_[0]};
}

1;
