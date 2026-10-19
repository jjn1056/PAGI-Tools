use strict;
use warnings;
use Test2::V0;
use Future;
use IO::Async::Loop;

use lib 'lib';
use PAGI::Middleware::ErrorHandler;
use PAGI::Exception::HTTP;
use PAGI::Response qw(response);

# ErrorHandler's catch: answers by status and exception class, in
# Starlette's order (an HTTP error's status, then the class and its
# ancestors, then the status any other error was given), before handler.

subtest 'construction' => sub {
    my $new = sub { PAGI::Middleware::ErrorHandler->new(@_) };
    like(dies { $new->(catch => { 600 => sub {} }) },
        qr/ErrorHandler catch key '600' is neither a status from 400 to 599 nor a package name/, 'a bad status');
    like(dies { $new->(catch => { 'My Class' => sub {} }) },
        qr/ErrorHandler catch key 'My Class' is neither a status/, 'not a package name');
    like(dies { $new->(catch => { '+My::X' => sub {} }) },
        qr/ErrorHandler catch key '\+My::X' is neither a status.*write 'My::X'/, 'a leading + is refused with a hint');
    like(dies { $new->(catch => { 404 => 'x' }) },
        qr/ErrorHandler catch entry for '404' must be a code reference/, 'a non-code value');
    like(dies { $new->(catch => [404, sub {}]) },
        qr/ErrorHandler catch must be a hash reference/, 'not a hash');
    ok(lives { $new->(catch => { 404 => sub {}, 'My::X' => sub {} }) }, 'a status and a class');
    ok(lives { $new->(status => 401, catch => { 401 => sub {} }) },
        'a field-required status option is accepted with a catch entry for it');
    like(dies { $new->(status => 401, catch => { 404 => sub {} }) },
        qr/must carry WWW-Authenticate/, 'but not with an entry for another status');
};

done_testing;
