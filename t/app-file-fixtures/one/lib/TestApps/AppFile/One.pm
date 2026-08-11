package TestApps::AppFile::One;

use strict;
use warnings;
use PAGI::App::File;

sub files {
    return PAGI::App::File->app_path('static');
}

1;
