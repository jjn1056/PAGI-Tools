package MyApp::View;

use v5.40;
use warnings;

sub document($class, $title, $body) {
    return <<"HTML";
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$title</title>
  <link rel="stylesheet" href="/static/app.css">
</head>
<body>
  <main class="page">
$body
  </main>
</body>
</html>
HTML
}

1;
