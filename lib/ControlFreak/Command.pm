package ControlFreak::Command;
use strict;
use warnings;

=encoding utf-8

=head1 NAME

ControlFreak::Command - turn string commands to method calls

=cut

sub process {
    my $class = shift;
    my $string = shift;

    ## clean
    $cmd =~ s/\#.*//;  # comments
    $cmd =~ s/^\s+//;  # leading whitespaces
    $cmd =~ s/\s+$//;  # trailing whitespaces

    return unless $string;

    my ($kw, $rest) = split /\s+/, $string;

}

"cd&c";
