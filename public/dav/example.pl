#!/usr/bin/env perl
use Mojolicious::Lite;

use lib 'lib';
plugin 'WebDAV';
plugin 'JsonConfig', file => 'server.conf';

app->start;
