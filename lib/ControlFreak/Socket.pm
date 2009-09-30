package ControlFreak::Socket;
use strict;
use warnings;

use Object::Tiny qw{
    name
    host
    service
    options
};

=head1 NAME

ControlFreak::Socket - Define a (shared) socket controlled by ControlFreak

=cut

=head1 SYNOPSIS

    $sock = ControlFreak::Socket->new(
        name    => "fcgisock",
        host    => "unix/",
        service => "/tmp/cfk-x.sock",
        options => "TBD",
    );
    $sock->connect(sub { $fh = shift });
    $sock->disconnect;

=head1 AUTHOR

Yann Kerherve <yannk@cpan.org>

=cut

"chaussette";
