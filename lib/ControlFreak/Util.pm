package ControlFreak::Util;

use strict;
use warnings;

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

1;
