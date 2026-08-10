use v5.40;
use warnings;
use File::Basename qw(dirname);
use lib dirname(__FILE__) . '/lib';
use MyApp::Root ();

MyApp::Root->to_app;
