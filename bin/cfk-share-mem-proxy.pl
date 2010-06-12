#!/usr/bin/env perl
use strict;
use warnings;

use Getopt::Long;
use AnyEvent();
use Data::Dumper;

use ControlFreak::Proxy::Process;
use Carp;
use Pod::Usage;

my $proxy;

my %options;
GetOptions(
    "p|preload=s"    => \$options{preload},

    'h|help'         => \$options{help},
    'm|man'          => \$options{man},
);

pod2usage(1)             if $options{help};
pod2usage(-verbose => 2) if $options{man};

croak "Please, specify a preload option" unless $options{preload};
my $svc_coderef;
my $ret = require $options{preload};
if ($ret && ref $ret eq 'CODE') {
    $svc_coderef = $ret;
}
croak "Error preloading: $@" if $@;

my $cfd = $ENV{_CFK_COMMAND_FD} or die "no command fd";
my $sfd = $ENV{_CFK_STATUS_FD}  or die "no status fd";
my $lfd = $ENV{_CFK_LOG_FD}     or die "no log fd";

open my $cfh, "<&=$cfd"
    or die "Cannot open Command filehandle, is descriptor correct?";

open my $sfh, ">>&=$sfd"
    or die "Cannot open Status filehandle, is descriptor correct?";

open my $lfh, ">>&=$lfd"
    or die "Cannot open Status filehandle, is descriptor correct?";

trap_sigs();

my $sockets = ControlFreak::Proxy::Process->sockets_from_env;
## FIXME: let Proxy::Process open the fd?
$proxy = ControlFreak::Proxy::Process->new(
    command_fh  => $cfh,
    status_fh   => $sfh,
    log_fh      => $lfh,
    sockets     => $sockets,
    svc_coderef => $svc_coderef,
);

$proxy->log('out', "$0 proxy started");
$proxy->run;

sub trap_sigs {
    $SIG{HUP} = $SIG{INT} = $SIG{TERM} = sub {
        my $sig = shift;
        if ($proxy) {
            $proxy->log("err", "Got signal $sig");
            $proxy->shutdown;
        }
        exit 0;
    };
    $SIG{__WARN__} = sub {
        my $warn = shift || "";
        $proxy->log("err", "warn $warn") if $proxy;
    };
    $SIG{__DIE__} = sub {
        my $reason = shift || "";
        return if $^S;
        $proxy->log("err", "die $reason") if $proxy;
        exit -1;
    };
}

__END__

=head1 NAME

cfk-share-mem-proxy.pl - a proxy process aimed at memory savings

=head1 SYNOPSIS

cfk-share-mem-proxy.pl [options]

Options:

 -p, --preload        A module/file that will be preloaded (using 'require')

 -h, --help           Help
 -m, --man            More help

=head1 OPTIONS

Please see L<SYNOPSIS>.

=head1 DESCRIPTION

Load some code/data in process' memory, and listen to C<ControlFreak> commands.
When instructed fork and exec a new command for a managed service. Reports
children events back to C<ControlFreak>.

=cut
