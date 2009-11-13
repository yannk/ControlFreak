package ControlFreak::Socket;
use strict;
use warnings;

use Carp();
use Object::Tiny qw{
    name
    host
    service
    nonblocking
    listen_qsize

    fh
};
use Params::Util qw{ _STRING };
use Scalar::Util();
use Socket qw(AF_INET AF_UNIX SOCK_STREAM SOL_SOCKET SO_REUSEADDR SOMAXCONN);
use AnyEvent::Util qw(fh_nonblocking AF_INET6);
use AnyEvent::Socket();

=head1 NAME

ControlFreak::Socket - Defines a (shared) socket controlled by ControlFreak

=cut

=head1 SYNOPSIS

    $sock = ControlFreak::Socket->new(
        ctrl    => $ctrl,
        name    => "fcgisock",
        host    => "unix/",
        service => "/tmp/cfk-x.sock",
        options => "TBD",
    );
    $sock->bind;
    $sock->unbind;
    $sock->set_host;
    $sock->set_service;
    print $sock->service;

=head1 DESCRIPTION

Each socket object has a unique name inside B<ControlFreak> controller,
services interested in a socket just reference it using this name.
The controller pipes the socket to children's stdin after forking,
and before executing the service.

=head1 METHODS

=head2 new(%param)

Creates a socket objects. Params are:

=over 4

=item * ctrl

The controller to attach the socket to. If not specified, the
socket object won't be created, C<new()> will just return undef.

=item * name

The name of the socket, MUST be unique within C<ctrl>.

=item * host

eg. '127.0.0.0', '0.0.0.0', 'unix/', '[::1]'.

=item * service

eg. '80', '/tmp/cfk.sock'.

=back

If a socket with that name already exists, it will return undef
and log the error.

=cut

sub new {
    my $class = shift;
    my %param = @_;

    delete $param{fh};
    my $ctrl = $param{ctrl};
    unless ($ctrl) {
        warn "Socket creation attempt without ctrl";
        return;
    }

    unless ($param{name}) {
        $ctrl->log->error("Socket creation attempt without a name");
        return;
    }

    my $socket = $class->SUPER::new(%param);
    $socket->{ctrl} = $ctrl;
    unless ($ctrl->add_socket($socket)) {
        $ctrl->log->error("A socket by that name already exists");
        return;
    }
    Scalar::Util::weaken($socket->{ctrl});
    return $socket;
}

=head2 bind

Creates, binds the socket and puts it in listen mode, then returns
immediately.
Once bound, $socket->fh will return the filehandle.

=cut

sub bind {
    my $socket = shift;

    my $ctrl = $socket->{ctrl};
    my $name = $socket->name;
    if ($socket->{fh}) {
        $ctrl->log->error("'$name' socket is already bound");
        return;
    }

    my ($fh, $host, $service) = $socket->_bind;
    unless ($fh) {
        $ctrl->log->error("cannot bind '$name': $!");
        return;
    }
    $ctrl->log->info("'$name' socket is now bound: $fh");
    ## reset with real values
    $socket->{service} = $service;
    $socket->{host}    = $host;
    $socket->{fh}      = $fh;
    return;
}

sub _bind {
    my $socket = shift;

    my $host = $socket->host;
    my $service = $socket->service;

    ## part reaped from AnyEvent::Socket

    my $ipn = AnyEvent::Socket::parse_address($host)
        or Carp::croak "AnyEvent::Socket::tcp_server: "
                     . "cannot parse '$host' as host address";

    my $af = AnyEvent::Socket::address_family($ipn);

    my $fh;

    # win32 perl is too stupid to get this right :/
    Carp::croak "tcp_server/socket: address family not supported"
        if AnyEvent::WIN32 && $af == AF_UNIX;

    socket $fh, $af, SOCK_STREAM, 0
        or Carp::croak "tcp_server/socket: $!";

   if ($af == AF_INET || $af == AF_INET6) {
       setsockopt $fh, SOL_SOCKET, SO_REUSEADDR, 1
           or Carp::croak "tcp_server/so_reuseaddr: $!"
       unless AnyEvent::WIN32; # work around windows bug

       unless ($service =~ /^\d*$/) {
           $service = (getservbyname $service, "tcp")[2]
               or Carp::croak "$service: service unknown"
       }
   } elsif ($af == AF_UNIX) {
       unlink $service;
   }

   CORE::bind $fh, AnyEvent::Socket::pack_sockaddr($service, $ipn)
       or Carp::croak "bind: $!";

   fh_nonblocking $fh, ($socket->nonblocking ? 1 : 0 );

   my $len = $socket->listen_qsize || SOMAXCONN;
   ($service, $host) = AnyEvent::Socket::unpack_sockaddr( getsockname $fh );
   ($host, $service) = (AnyEvent::Socket::format_address($host), $service);

   listen $fh, $len or Carp::croak "listen: $!";
   return ($fh, $host, $service);
}

=head2 is_bound

Returns true if the socket is bound.

=cut

sub is_bound {
    return shift->{fh} ? 1 : 0;
}

=head2 unbind()

Unbind and destroys the socket.

=cut

sub unbind {
    my $socket = shift;
    return unless $socket->is_bound;
    $socket->{fh} = undef;
    return 1;
}

sub set_host {
    my $sock = shift;
    my $value = _STRING($_[0]) or return;
    $value =~ s/[\n\r\t\0]+//g; ## desc should be one line
    $sock->{host} = $value;
    return 1;
}

sub set_service {
    my $sock = shift;
    my $value = _STRING($_[0]) or return;
    $value =~ s/[\n\r\t\0]+//g; ## desc should be one line
    $sock->{service} = $value;
    return 1;
}

sub set_nonblocking {
    my $sock = shift;
    my $value = shift() ? 1 : 0;
    $sock->{nonblocking} = $value;
    return 1;
}

sub set_listen_qsize {
    my $sock = shift;
    my $size = shift;
    $size = SOMAXCONN if $size && $size =~ /^\s*max\s*$/i;
    my $value = _NUMBER($size) || 0;
    $sock->{listen_qsize} = $value;
}

sub unset {
    my $sock = shift;
    my $attr = shift || "";
    $sock->{$attr} = undef;
    return 1;
}

=head1 AUTHOR

Yann Kerherve <yannk@cpan.org>

=cut

"chaussette";
