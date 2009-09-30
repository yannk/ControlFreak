package ControlFreak::Console;
use strict;
use warnings;

use Object::Tiny qw{
    host
    service
    full
};

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

=head1 AUTHOR

Yann Kerherve <yannk@cpan.org>

=cut

"con=console";
