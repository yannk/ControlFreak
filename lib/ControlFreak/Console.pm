package ControlFreak::Console;
use strict;
use warnings;

use Log::Log4perl qw/:easy/;
Log::Log4perl->easy_init($DEBUG);
use Carp;
use AnyEvent::Socket();
use AnyEvent::Handle();

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
    $param{ctrl}->set_console($console);
    $console->{started} = 0;
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

Start the console and return guard for it.

=cut

sub start {
    my $console = shift;
    my %param   = @_;
    my $ctrl = $console->{ctrl};

    my $accept_cb = sub {
        my ($fh, $host, $port) = @_;
        INFO "new connection to admin from $host:$port";
        $console->accept_connection($fh, $host, $port);
    };

    my $prepare_cb = sub {
        my ($fh, $host, $port) = @_;
        INFO "Admin interface started on $host:$port";
        $param{prepare_cb}->(@_) if $param{prepare_cb};
        return 0;
    };

    $console->{started} = 1;
    my $host = $console->host;
    my $service = $console->service;
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
            INFO "client connection: eof";
            $hdl->destroy;
        },
        on_error => sub {
            ERROR "Client connection error: $!";
        },
    );
    $console->{handles}{$hdl} = $hdl;

    my $get_admin_cmd; $get_admin_cmd = sub {
        my ($h, $line) = @_;
        if (lc $line eq 'exit') {
            INFO "exiting";
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
                my $error = shift;
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
    $hdl->push_write("cfkcon>$CRLF");
}

=head1 AUTHOR

Yann Kerherve <yannk@cpan.org>

=cut

"con=console";
