#!/usr/bin/env perl
use v5.40;
use File::Basename qw(dirname);
use lib dirname(__FILE__) . '/lib';
use Mini;
use PAGI::Exception::HTTP;

my %NOTES = (acme => { 7 => 'buy apples' });

Mini->new
    # A bridge: runs for every /tenants/{tenant}/... and continues ('next').
    ->get('^/tenants/(?<tenant>\w+)/' => sub ($req, $res) {
        PAGI::Exception::HTTP->throw(404, 'No such tenant')
            unless $NOTES{ $req->path_param('tenant') };
        return 'next';
    })
    ->get('^/tenants/(?<tenant>\w+)/notes/(?<id>\d+)$' => sub ($req, $res) {
        my $note = $NOTES{ $req->path_param('tenant') }{ $req->path_param('id') }
            // PAGI::Exception::HTTP->throw(404, 'No such note');
        $res->json({ note => $note });
    })
    # 401 with its challenge, no ErrorHandler handler needed (§4.2).
    ->get('^/private$' => sub ($req, $res) {
        PAGI::Exception::HTTP->throw(401, 'Login required',
            headers => [['WWW-Authenticate', 'Bearer realm="mini"']]);
    })
    # A no-body status through the generic path (§3.2), with a staged cookie.
    ->get('^/seen$' => sub ($req, $res) {
        $res->status(204)->cookie(seen => 1);
    })
    # Bytes with the framework's chosen type (§3.4: explicit beats default).
    ->get('^/pixel$' => sub ($req, $res) {
        $res->bytes("GIF89a\x01\x00\x01\x00")->content_type('image/gif');
    })
    # Text with a staged type keeps Text's charset (§3.6).
    ->get('^/csv$' => sub ($req, $res) {
        $res->text("a,b\n1,2\n")->content_type('text/csv');
    })
    # An untyped, bodyless redirect: no Content-Type, as Starlette's base (§3.4).
    ->get('^/old$' => sub ($req, $res) {
        $res->status(302)->header(Location => '/tenants/acme/notes/7');
    })
    ->to_app;
