package ControlFreak::Console;
use strict;
use warnings;

use AnyEvent::Socket;
use Log::Log4perl qw/:easy/;
Log::Log4perl->easy_init($DEBUG);
use Carp;

use Object::Tiny qw{
    host
    service
    full
};

sub new {
    my $console = shift->SUPER::new(@_);
    my %param = @_;
    $console->{cntl} = $param{cntl}
        or croak "Console requires a controller";
    $param{cntl}->set_console($console);
    return $console;
}

sub add_handle {
    my $console = shift;
}

=head1 NAME

ControlFreak::Console - Handles all communications with ControlFreak

=cut

=head1 SYNOPSIS

    $con = ControlFreak::Console->new(
        host    => $host,
        service => $service,
        full    => 1,
        cntl    => $cntl,
    );
    $con->start;

    ## return all the current connection handles
    @hdls = $con->conns;

    $con->add_conn($hdl);

    $ok = $con->process_command($string);

    $con->stop;

=head1 METHODS

=head2 start

Start the console and return guard for it.

=cut

sub start {
    my $console = shift;
    my $cntl = $console->{cntl};

    my $accept_cb = sub {
        my ($fh, $host, $port) = @_;
        INFO "new connection to admin $host:$port";
#        $cntl->accept_admin_connection($fh);
    };

    my $prepare_cb = sub {
        my ($fh, $host, $port) = @_;
        INFO "Admin interface started on $host:$port";
        return 0;
    };

    my $host = $console->host;
    my $service = $console->service;
    my $guard = tcp_server $host, $service, $accept_cb, $prepare_cb;
    return $guard;
}
=head1 AUTHOR

Yann Kerherve <yannk@cpan.org>

=cut

"con=console";
