#!/usr/bin/env perl
# One CGI script whose behaviour t/app-wrapcgi.t picks with QUERY_STRING
# (mode=NAME, plus optional pidfile=PATH to report the process id).
use strict;
use warnings;

my %q = map { split /=/, $_, 2 } split /&/, $ENV{QUERY_STRING} // '';
if (my $pidfile = $q{pidfile}) {
    open my $fh, '>', $pidfile or die "$pidfile: $!";
    print {$fh} $$;
    close $fh;
}
$| = 1;
binmode STDIN;
binmode STDOUT;
my $mode = $q{mode} // 'env';

if ($mode eq 'echo') {
    my $in = '';
    read(STDIN, $in, $ENV{CONTENT_LENGTH} // 0);
    print "Content-Type: application/octet-stream\r\n\r\n$in";
}
elsif ($mode eq 'big') {                     # 5MB, as fast as the pipe allows
    print "Content-Type: application/octet-stream\r\n\r\n";
    print 'x' x 65536 for 1 .. 80;
}
elsif ($mode eq 'bigio') {                   # writes 1MB before reading 1MB
    print "Content-Type: text/plain\r\n\r\n";
    print 'y' x 65536 for 1 .. 16;
    my $in = '';
    read(STDIN, $in, $ENV{CONTENT_LENGTH} // 0);
    print "\nread ", length($in), "\n";
}
elsif ($mode eq 'slow_head') { sleep 30; print "Content-Type: text/plain\r\n\r\nlate" }
elsif ($mode eq 'stubborn') { $SIG{TERM} = 'IGNORE'; sleep 30 }
elsif ($mode eq 'slow_body') {
    print "Content-Type: text/plain\r\n\r\nfirst\n";
    sleep 30;
    print "never\n";
}
elsif ($mode eq 'garbage') { print "this is not a header block" }
elsif ($mode eq 'empty')   { }
elsif ($mode eq 'status')  { print "Status: 404 Not Here\r\nContent-Type: text/plain\r\nX-From: cgi\r\n\r\nmissing" }
elsif ($mode eq 'location') { print "Location: https://example.com/elsewhere\r\n\r\n" }
else {                                        # env: the CGI variables, one per line
    print "Content-Type: text/plain\r\n\r\n";
    for my $name (qw(GATEWAY_INTERFACE REQUEST_METHOD SCRIPT_NAME PATH_INFO REQUEST_URI
                     QUERY_STRING SERVER_PROTOCOL CONTENT_TYPE CONTENT_LENGTH HTTPS
                     HTTP_ACCEPT HTTP_X_MULTI HTTP_PROXY)) {
        print "$name=", (exists $ENV{$name} ? "[$ENV{$name}]" : 'unset'), "\n";
    }
    print 'PATH=', (defined $ENV{PATH} && length $ENV{PATH} ? 'set' : 'unset'), "\n";
    print 'HOME=', (exists $ENV{HOME} ? 'set' : 'unset'), "\n";
}
