#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use Future::AsyncAwait;

use MyApp::Main;

# Return the app
MyApp::Main->to_app;
