package ControlFreak::Util;

use strict;
use warnings;
use POSIX();

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
