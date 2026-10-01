use strict;
use warnings;
use utf8;
use Test2::V0;
use lib 'lib';
use PAGI::Utils::Scope;

# raw_path is the full requested path, encoded, at every mount level;
# request_uri adds the query; raw_path_info is the encoded part below
# root_path. See PAGI::Spec::Www "Paths, Mounts and Root Paths".

sub scope { return { root_path => '', query_string => '', @_ } }

subtest 'request_uri' => sub {
    my @cases = (
        [ 'root',            scope(path => '/reports', raw_path => '/reports', query_string => 'x=1'), '/reports?x=1' ],
        [ 'inside a mount',  scope(root_path => '/admin', path => '/users', raw_path => '/admin/users'), '/admin/users' ],
        [ 'no raw_path',     scope(root_path => '/café', path => '/menu é', query_string => 'q=1'),     '/caf%C3%A9/menu%20%C3%A9?q=1' ],
        [ 'raw UTF-8 bytes', scope(path => '/café', raw_path => "/caf\xC3\xA9"),                          '/caf%C3%A9' ],
        [ 'control bytes',   scope(path => '/x', raw_path => '/x', query_string => "a=1\x0D\x0Ab"),       '/x?a=1%0D%0Ab' ],
        [ 'leading //',      scope(path => '//evil.example/x', raw_path => '//evil.example/x'),           '/evil.example/x' ],
        [ 'characters a URI cannot hold, in the query', scope(path => '/s', raw_path => '/s', query_string => 'q={"x":1}|a^b<c>[d]#e'),
          '/s?q=%7B%22x%22:1%7D%7Ca%5Eb%3Cc%3E%5Bd%5D%23e' ],
        [ 'and in the path',  scope(path => '/a^b`c', raw_path => '/a^b`c'),                                '/a%5Eb%60c' ],
        [ 'a backslash cannot make //', scope(path => '/\\evil.example', raw_path => '/\\evil.example'), '/%5Cevil.example' ],
        [ 'what a query may hold stays', scope(path => '/s', raw_path => '/s', query_string => "a=1&b=x:y/z?w;v=(1)!*'+,\$\@~%2F"),
          "/s?a=1&b=x:y/z?w;v=(1)!*'+,\$\@~%2F" ],
        [ 'a ? in a hand-built raw_path is escaped', scope(path => '/a?b', raw_path => '/a?b', query_string => 'q=1'), '/a%3Fb?q=1' ],
        [ 'bytes and characters do not double-encode', scope(path => '/café', raw_path => "/caf\xC3\xA9", query_string => "q=\x{263A}"),
          '/caf%C3%A9?q=%E2%98%BA' ],
    );
    for my $case (@cases) {
        my ($label, $scope, $expected) = @$case;
        is(PAGI::Utils::Scope::request_uri($scope), $expected, $label);
    }
};

subtest 'raw_path' => sub {
    is(PAGI::Utils::Scope::raw_path(scope(path => '/x', raw_path => '/a%2Fx')), '/a%2Fx', 'the scope value');
    is(PAGI::Utils::Scope::raw_path(scope(root_path => '/admin', path => '/users')), '/admin/users',
        'without one: root_path and path, encoded');
};

subtest 'raw_path_info' => sub {
    my @cases = (
        [ 'root',                          scope(path => '/x', raw_path => '/x'),                                        '/x' ],
        [ 'encoded prefix letter',         scope(root_path => '/admin', path => '/users', raw_path => '/%61dmin/users'), '/users' ],
        [ 'encoded slash below the mount', scope(root_path => '/files', path => '/a/b', raw_path => '/files/a%2Fb'),     '/a%2Fb' ],
        [ 'encoded slash across it',       scope(root_path => '/files', path => '/a', raw_path => '/files%2Fa'),         undef ],
        [ 'path was rewritten',            scope(path => '/new', raw_path => '/old'),                                    undef ],
        [ 'non-ASCII root',                scope(root_path => '/café', path => '/menu', raw_path => '/caf%C3%A9/menu'),  '/menu' ],
        [ 'byte-fallback root',            scope(root_path => "/caf\xE9", path => '/x', raw_path => '/caf%E9/x'),        '/x' ],
        [ 'literal % in the root',         scope(root_path => '/b%ff', path => '/c', raw_path => '/b%25ff/c'),           '/c' ],
        [ 'exact mount',                   scope(root_path => '/admin', path => '/', raw_path => '/admin'),              '/' ],
        [ 'raw_path elsewhere',            scope(root_path => '/admin', path => '/x', raw_path => '/other/x'),           undef ],
        [ 'no raw_path',                   scope(root_path => '/a', path => '/a b'),                                     '/a%20b' ],
    );
    for my $case (@cases) {
        my ($label, $scope, $expected) = @$case;
        is(PAGI::Utils::Scope::raw_path_info($scope), $expected, $label);
    }
};

subtest 'path_for and the helpers share one encoder' => sub {
    is(PAGI::Utils::Scope::_encode_path('/caf é~'), '/caf%20%C3%A9~', 'unreserved and / stay literal');
};

done_testing;
