package Mojolicious::Plugin::WebDAV;
use Mojo::Base 'Mojolicious::Plugin';

use Mojo::URL;
use Mojo::Asset::File;
use Mojo::ByteStream 'b';
use Data::Dumper qw/Dumper/;
use Date::Format;

#use Mojo::Asset::File;
#use File::Copy::Recursive qw( rcopy rmove );
#use File::Path qw( mkpath rmtree );
#use File::Spec qw();
#use HTTP::Date qw();
#use Fcntl qw( O_WRONLY O_TRUNC O_CREAT );
#use bytes;

# I feel dirty
#use XML::LibXML;

#has [qw/ mtfnpy /];
has methods => sub { [ qw( GET HEAD OPTIONS PROPFIND
                           DELETE PUT COPY LOCK UNLOCK
                           MOVE POST TRACE MKCOL ) ] };
has allowed_methods => sub { join( ',', @{ shift->methods } ) };

sub register {
  my ($self, $app, $config) = @_;
  $config ||= {};

  my $webdav_count = 1;

  # Add type
  $app->types->type(unixd => 'httpd/unix-directory');

  $app->routes->add_shortcut(
    webdav => sub {
      my $route = shift;

      my $route_name = 'webdav-' . $webdav_count++;
      $route->name($route_name);

      # Root to webdav folder
      my $root  = $_[0] ? shift . '/' : '';

      # File path
      my $webdav = $route->bridge('/*wdpath', wdpath => qr/.*/)->to(
	cb => sub { $self->_default_values( shift, $root, $route_name) }
      );

      # Root path
      my $webdav_root = $route->bridge->to(
	cb => sub { $self->_default_values( shift, $root, $route_name) }
      );

      $webdav->route->to( cb => sub { $self->_handle_req(@_) } );
      $webdav_root->route->to( cb => sub { $self->_handle_req(@_) } );
    }
  );
};

sub _handle_req {
  my ($self, $c) = @_;

  my $method = lc $c->req->method;

  return $c->rendered(405) unless $method ~~ [qw/options put propfind/];

  # XXX revisit this
  $c->stash(
    'dav.absroot' =>
      File::Spec->catdir(
	$c->app->static->root,
	$c->stash('dav.root')
      ));

  my $cmd = "cmd_$method";

  return $self->$cmd($c);
};


sub _default_values {
  my ($self, $c, $root, $route_name) = @_;

  # Default headers
  for ($c->res->headers) {
    $_->header('DAV' => '1,2,<http://apache.org/dav/propset/fs/1>');
    $_->header('MS-Author-Via' => 'DAV');
  };

  my $method = lc $c->req->method;

  # No path processing necessary
  return 1 if $method eq 'options';

  # Canonicalize path
  my $path = Mojo::Path->new($root . ($c->stash('wdpath') || ''));

  my $prefix = $c->url_for($route_name)->path->to_string;
  my $parts = Mojo::Path->new($c->stash('wdpath'))->parts;

  my $abs_root = File::Spec->catdir( $c->app->static->root, $root);
  my $abs_path = File::Spec->catfile( $abs_root, @$parts );

  $c->stash(
    'dav.request' => 1,
    'dav.rel'     => $c->stash('wdpath') || '/',  # File::Spec->catfile( @$parts ) || '/',
    'dav.path'    => $path->canonicalize->to_string,
#    'dav.relpath' => ,
    'dav.root'    => $root,
    # XXX revisit this
    'dav.absroot' => $abs_root,
    'dav.abspath' => $abs_path,
    'dav.name'    => $route_name,
    'dav.prefix'  => $prefix
    );

  # Todo: In case of Collections this should link to .../
  $c->res->headers->header('Content-Location' => $prefix . $c->stash('dav.rel'));

  # Bridge successful
  return 1;
};


sub cmd_options {
  my ($self, $c) = @_;

  warn Dumper $c->req->body;

  # Allowed methods header
  $c->res->headers->header(Allow => $self->allowed_methods );

  return $c->render(
    status => 200,
    format => 'unixd',
    text   => ''
  );
};


sub cmd_put {
  my ($self, $c) = @_;

  # Nothing to put
  unless ($c->req->headers->content_length) {
    return $c->rendered(403);
  };

  # TODO check if $c->req has the asset we can move

  my $path = $c->stash('dav.path');

  # Path is a directory ???
  if ( -d $path ) {
    # 8.7.2
    return $c->rendered(409);
  };

  my $file = Mojo::Asset::File->new(
    path => $path,
    cleanup => 0
  );

  $file->add_chunk($c->req->body || '');

  # created
  return $c->render(
    text   => 'Created',
    status => 201
  );
};



sub cmd_propfind {
  my ($self, $c) = @_;
  my $req = $c->req;

  # 'Allprop' is default
  my $reqinfo = 'allprop';
  my @reqprops = ();

  # Empty request
  if ( $req->headers->content_length ) {

    my $dom = Mojo::DOM->new;
    $dom->xml(1);
    $dom->parse($c->req->body);

    my @reqprops;

    my $propchild = $dom->at('propfind > *');

    $reqinfo = $propchild->tree->[1];

    if ($propchild->tree->[1] =~ /(?:^|:)prop$/) {
      $propchild->children->each(
	sub {
	  my $tag = $_->tree->[1];
	  $tag =~ s/^(?:[^:]+:)?([^:]+?)$/$1/o;
	  push(@reqprops, [$_->namespace, $1]);
	});
    };
  };

  my $abspath = $c->stash('dav.abspath');

  return $c->render_not_found unless -e $abspath;

  my $depth = $req->headers->header('Depth');
  $depth = ( defined $depth && $depth ~~ [0,1] ) ? $depth : 'infinite';


  # Select paths
  my @paths;
  if ($depth ne 'infinite' && -d $abspath) {
    opendir( my $dir, $abspath );

    # Delete all paths that go upwards
    @paths = File::Spec->no_upwards( readdir($dir) );

    closedir( $dir );

    push( @paths, '/' ) unless $depth;
  }

  # Infinite
  else {
    @paths = ( '/' );
  };

  my %prefixes = ( 'DAV:' => 'D' );
  my @response;

  # Check subtree entries
  foreach my $rel ( @paths ) {
    my %entry;

    # path to the entry
    my $path = File::Spec->catdir( $abspath, $rel );

    # Stats of the entry
    my ( $size, $mtime, $ctime ) = ( stat( $path ) )[ 7, 9, 10 ];

    # TODO: easier?
    # modified time is stringified human readable HTTP::Date style
    #        $mtime = HTTP::Date::time2str($mtime);
    for ($mtime, $ctime) {
      $_ = Date::Format::time2str( '%a, %d %b %Y %H:%M:%S %z', $_ );
    };

    # Define size if undef
    $size ||= '';

    # Write URI based on entry
    my $uri = File::Spec->catdir(
      $c->stash('dav.prefix'),
      $c->stash('dav.rel'),
      map { b($_)->url_escape->to_string } File::Spec->splitdir( $rel )
    );

    # XXX check if this works
    $uri .= '/' if -d $path && $uri !~ m/\/$/;

    # TODO: Unnecessary if dav.prefix has leading /
    $uri = '/'.$uri unless $uri =~ m/^\//;

    $entry{href} = $uri;

    # First prefix of unknown prefixes
    my $n = 'E';

    # Prop
    if ($reqinfo eq 'prop') {
      foreach my $reqprop ( @reqprops ) {
	my ($ns, $name) = @$reqprop;

	if ($ns eq 'DAV:') {
	  # creationdate
	  if ($name eq 'creationdate') {
	    $entry{creationdate} = $ctime;
	    $entry{ok} = 1;
	  }

	  # getcontentlength
	  elsif ($name eq 'getcontentlength') {
	    $entry{getcontentlength} = $size;
	    $entry{ok} = 1;
	  }

	  # getcontenttype
	  elsif ($name eq 'getcontenttype') {
	    if (-d $path) {
	      $entry{getcontenttype} = 'httpd/unix-directory';
	    }

	    else {
	      # crude
	      my ($ext) = $path =~ m/\.([^\.]+)$/;
	      my $ct = 'httpd/unix-file';
	      $ct = ($c->app->types->type( lc $ext ) || $ct) if $ext;
	      $entry{getcontenttype} = $ct;
	    };
	    $entry{ok} = 1;
	  }

	  # getlastmodified
	  elsif ($name eq 'getlastmodified') {
	    $entry{'getlastmodified'} = $mtime;
	    $entry{ok} = 1;
	  }

	  # resourcetype
	  elsif ($name eq 'resourcetype') {
	    $entry{resourcetype} = '';
	    # TODO Change this to check only once for -d
	    $entry{resourcetype} = 'collection' if -d $path;
	    $entry{ok} = 1;
	  }

	  # Unknown prop in DAV:
	  else {
	    $entry{bad} //= [];
	    push (@{$entry{bad}}, 'D:'.$name);
	  };
	}

	# Unknown namespace
	else {
	  $entry{bad} //= [];
	  my $prefix = $prefixes{ $ns };
	  # mod_dav sets <response> 'xmlns' attribute
	  unless ($prefix && $n != 'Z') {
	    $prefixes{$ns} = $n;
	    push (@{$entry{bad}}, $n . ':' . $name);
	    $n++;
	  };
	};
      };
    }

    # Propname
    elsif ($reqinfo eq 'propname') {
      # All empty
      $entry{propname} = 1;
    }

    # Else
    else {
      $entry{ok} = 1;
      $entry{creationdate} = $ctime;
      $entry{getcontentlength} = $size;

      if (-d $path) {
	$entry{getcontenttype} = 'httpd/unix-directory';
      }

      else {
	# crude
	my ($ext) = $path =~ m/\.([^\.]+)$/;
	my $ct = 'httpd/unix-file';
	$ct = ($c->app->types->type( lc $ext ) || $ct) if $ext;
	$entry{getcontenttype} = $ct;
      };

      $entry{getlastmodified} = $mtime;
      $entry{resourcetype} = '';
      # TODO Change this to check only once for -d
      $entry{resourcetype} = 'collection' if -d $path;

      # TODO: supportedlock
    };

    # Push entry to response array
    push(@response, \%entry);
  };

  return $c->render(
    status         => 207,
    template       => 'dav',
    format         => 'xml',
    template_class => __PACKAGE__,
    response       => \@response,
    prefixes       => \%prefixes
  );
};


# Make collection
sub cmd_mkcol {
  my ($self, $c) = @_;
  my $path = $c->stash('dav.abspath');

  # 8.3.1
  return $c->rendered(403) if $c->stash( 'dav.path' ) eq '/';
  return $c->rendered(415) if $c->req->headers->content_length;
  return $c->rendered(405) if -e $path;
  return $c->rendered(409) unless mkdir( $path, 0755 );

  return $c->render_text('Created', status => 201);
}


1;

__DATA__

@@ dav.xml.ep
% my $d_info = 'xmlns:b="urn:uuid:c2f41010-65b3-11d1-a29f-00aa00c14882/" '.
%              'b:dt="dateTime.rfc1123"';
% my ($e, $key);
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<D:multistatus<% foreach $key (keys %$prefixes) { %> xmlns:<%= $key %>="<%= $prefixes->{$key} %>"<% } %>>
% foreach $e (@$response) {
  <D:response>
    <D:href><%= $e->{href} %></D:href>
%   if ($e->{propname}) {
    <D:propstat>
      <D:prop>
        <D:creationdate />
        <D:getcontentlength />
        <D:getcontenttype />
        <D:getlastmodified />
        <D:resourcetype />
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
%   } elsif ($e->{ok}) {
    <D:propstat>
      <D:prop>
%     if (defined $e->{creationdate}) {
        <D:creationdate <%== $d_info %>><%= $e->{creationdate} %></D:creationdate>
%     };
%     if (defined $e->{getlastmodified}) {
        <D:getlastmodified <%== $d_info %>><%= $e->{getlastmodified} %></D:getlastmodified>
%     };
%     if (defined $e->{getcontentlength}) {
       <D:getcontentlength><%= $e->{getcontentlength} %></D:getcontentlength>
%     };
%     if (defined $e->{getcontenttype}) {
       <D:getcontenttype><%= $e->{getcontenttype} %></D:getcontenttype>
%     };
%     if (defined $e->{resourcetype}) {
%       if ($e->{resourcetype} eq 'collection') {
       <D:resourcetype><D:collection /></D:resourcetype>
%       } else {
       <D:resourcetype />
%       };
%     };
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
%   };
%   if ($e->{bad}) {
    <D:propstat>
%     foreach my $bad (@{$e->{bad}}) {
        <D:prop><<%== $bad %>/></D:prop>
%     };
      <D:status>HTTP/1.1 404 Not Found</D:status>
    </D:propstat>
%   };
  </D:response>
% }
</D:multistatus>

__END__
