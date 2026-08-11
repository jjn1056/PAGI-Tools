package TestApps::AppPath::Root;

use strict;
use warnings;
use PAGI::Utils qw(app_path);

sub home  { return app_path() }
sub child { shift; return app_path(@_) }

1;
