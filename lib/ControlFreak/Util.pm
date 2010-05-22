package ControlFreak::Util;

use strict;
use warnings;
use IO::Socket::UNIX();
use IO::Socket::INET();
use POSIX();
use Socket qw(SOCK_STREAM);

sub parse_unix {
    my $address = shift || "";

    if ($address =~ m!^unix:(.+)!) {
        return $1;
    }
    elsif ($address =~ m!^/!) {
        return $address;
    }
    ## relative path to a socket. This is bad, maybe I'd better ignore it?
    elsif ($address =~ m!^\w.*/! && $address !~ m!:!) {
        return $address;
    }
    return;
}

sub get_sock_from_addr {
    my $address = shift;

    my $unix = parse_unix($address);

    if ($unix) {
        return IO::Socket::UNIX->new(
            Type => SOCK_STREAM,
            Peer => $unix,
        );
    }

    $address =~ s{/+$}{};
    my $sock = IO::Socket::INET->new(
        PeerAddr => $address,
        Proto    => 'tcp',
    );
    return unless $sock;
    $sock->autoflush(1);
    return $sock;
}

## conveniently, log to the "log" priority,
## and call the error callback if one is specified.
sub error {
    my $object = shift;
    my $err_msg = pop;
    my %param = @_;

    my $log = $object->{ctrl}->log;
    $log->error($err_msg);
    my $err_cb = $param{err_cb} || sub {};
    return $err_cb->($err_msg);
}

sub exit_reason {
    my $status = shift;

    my $exit_status = POSIX::WEXITSTATUS($status);
    my $signal      = POSIX::WTERMSIG($status);

    my ($exit, $sig);
    if (POSIX::WIFEXITED($status)) {
        $exit = $exit_status
              ? "Exited with error $exit_status"
              : "Exited successfuly";
    }

    $sig = "Received signal $signal" if POSIX::WIFSIGNALED($status);
    return join " - ", grep { $_ } ($exit, $sig);
}

1;
