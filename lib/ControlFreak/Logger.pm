package ControlFreak::Logger;
use strict;
use warnings;

use Log::Log4perl;
use Log::Log4perl::Level;

use Object::Tiny qw{ ctrl };

sub svc_watcher {
    my $logger = shift;
    ## type is 'out' our 'err'
    my ($type, $svcname) = @_;

    my $l4p = Log::Log4perl->get_logger("service.$svcname.$type");
    ## configurable?
    my $loglevel = $type eq 'err' ? $ERROR : $INFO;
    my $watcher_cb = sub {
        my $msg = shift;
        return unless defined $msg;
        chomp $msg if $msg;
        $l4p->log($loglevel, $msg);
        return;
    };
    return $watcher_cb;
}

=head1 NAME

ControlFreak::Logger - All about logging

=cut

=head1 SYNOPSIS

=head1 AUTHOR

Yann Kerherve <yannk@cpan.org>

=cut

"zog-zog"

