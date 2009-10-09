#!/usr/bin/perl
use strict;
use warnings;
$|++;

my $id = shift || "someservice";
my $stop_after = shift || 1;
open my $stdin, "<&=0" or die "where is stdin?: $!";
my $i = 0;
while (accept(SOCKET, $stdin) or die "snif: $!" ) {
    while (<SOCKET>) {
        print "$id $_\n";
    }
    last if ++$i >= $stop_after;
}
