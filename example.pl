#!/usr/bin/env perl
use Mojolicious::Lite;

use lib 'lib';
use lib '../lib';

app->secret('fztzhgvhdgvftfdn');

plugin 'WebDAV';
#plugin 'JsonConfig', file => 'server.conf';

get '/' => sub {
  my $c = shift;
  return $c->render_text('Test');
};

(any '/webdav')->webdav('dav');

app->start;
