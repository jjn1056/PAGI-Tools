use strict;
use warnings;
use FindBin;
use PAGI::App::File;

# PAGI::App::File Example
# Run with: pagi-server ./examples/app-01-file/app.pl --port 5000
#
# Features demonstrated:
#   - Static file serving from a root directory
#   - Index file resolution (index.html)
#   - MIME type detection
#   - ETag caching (304 Not Modified)
#   - Range requests for partial content
#   - Path traversal protection
#
# Test URLs:
#   http://localhost:5000/           -> index.html
#   http://localhost:5000/test.txt   -> plain text
#   http://localhost:5000/data.json  -> JSON
#   http://localhost:5000/style.css  -> CSS
#   http://localhost:5000/subdir/nested.txt -> nested file

my $app = PAGI::App::File->new(
    root => "$FindBin::Bin/static",
)->to_app;

$app;
