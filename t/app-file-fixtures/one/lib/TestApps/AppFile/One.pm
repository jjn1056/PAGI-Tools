package TestApps::AppFile::One;

use strict;
use warnings;
use PAGI::App::File;

sub files {
    return PAGI::App::File->from_app_path('static');
}

1;
