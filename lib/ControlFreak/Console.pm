package ControlFreak::Console;
use strict;
use warnings;

use Carp;
use AnyEvent::Socket();
use AnyEvent::Handle();
use Scalar::Util();

our $CRLF = "\015\12";

use Object::Tiny qw{
    host
    service
    full
    started
};

sub new {
    my $console = shift->SUPER::new(@_);
    my %param = @_;
    $console->{ctrl} = $param{ctrl}
        or croak "Console requires a controller";
    Scalar::Util::weaken($console->{ctrl});
    $console->{started} = 0;
    $param{ctrl}->set_console($console);
    $console->{full} = 1;
    return $console;
}

=head1 NAME

ControlFreak::Console - Handles all communications with ControlFreak

=cut

=head1 SYNOPSIS

    $con = ControlFreak::Console->new(
        host    => $host,
        service => $service,
        full    => 1,
        ctrl    => $ctrl,
    );
    $con->start;

    ## return all the current connection handles
    @hdls = $con->conns;

    $con->add_conn($hdl);

    $ok = $con->process_command($string);

    $con->stop;

=head1 METHODS

=head2 start

Starts the console

=cut

sub start {
    my $console = shift;
    my %param   = @_;
    my $ctrl = $console->{ctrl};

    my $service = $console->service;
    my $accept_cb = sub {
        my ($fh, $host, $port) = @_;
        my $addr = $host eq 'unix/'
                 ? "$host:$service"
                 :  AnyEvent::Socket::format_hostport($host, $port);
        $ctrl->log->info("new connection to admin from $addr");
        $console->accept_connection($fh, $host, $port);
    };

    my $prepare_cb = sub {
        my ($fh, $host, $port) = @_;
        $ctrl->log->info("Admin interface started on $host:$port");
        $param{prepare_cb}->(@_) if $param{prepare_cb};
        return 0;
    };

    $console->{started} = 1;
    my $host = $console->host;
    my $guard = AnyEvent::Socket::tcp_server
                $host, $service, $accept_cb, $prepare_cb;
    $console->{guard} = $guard;
    return 1;
}

sub accept_connection {
   my $console = shift;
   my ($fh, $host, $service) = @_;

    my $hdl; $hdl = AnyEvent::Handle->new(
        fh       => $fh,
        on_eof   => sub {
            $console->{ctrl}->log->info("Console connection: eof");
            $hdl->destroy;
        },
        on_error => sub {
            $console->{ctrl}->log->error("Console connection error: $!");
            $hdl->destroy;
        },
    );
    $console->{handles}{$hdl} = $hdl;

    my $get_admin_cmd; $get_admin_cmd = sub {
        my ($h, $line) = @_;
        if (lc $line eq 'exit') {
            $console->{ctrl}->log->info( "Console exiting" );
            $h->on_drain(sub {
                delete $console->{handles}{$h};
                $h->destroy;
            });
            return 1;
        }

        ControlFreak::Command->process(
            cmd => $line,
            ctrl => $console->{ctrl},
            err_cb => sub {
                my $error = shift || "";
                $h->push_write("ERROR: $error$CRLF");
            },
            ok_cb => sub {
                my $out = shift || "";
                $out .= "\n" if $out;
                $h->push_write("${out}OK$CRLF");
            },
            has_priv => $console->full,
        );

        ## continue reading
        $h->push_read( line => $get_admin_cmd );
    };

    $hdl->push_read( line => $get_admin_cmd );
}

=head1 AUTHOR

Yann Kerherve <yannk@cpan.org>

=cut

"con=console";
