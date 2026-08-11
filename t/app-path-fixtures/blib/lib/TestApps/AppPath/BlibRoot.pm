package TestApps::AppPath::BlibRoot;

use strict;
use warnings;
use PAGI::Utils qw(app_path);

sub home { return app_path() }

1;
