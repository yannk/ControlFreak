package ControlFreak::Logger;
use strict;
use warnings;

use Carp;
use Log::Log4perl();

use Params::Util qw{ _STRING };
use Object::Tiny qw{ config_file };

our $CURRENT_SVC_PID;

Log::Log4perl::Layout::PatternLayout::add_global_cspec(
    'S', sub { $ControlFreak::Logger::CURRENT_SVC_PID || "-" },
);

sub new {
    my $class = shift;
    my $logger = $class->SUPER::new(@_);

    if (my $config_file = $logger->config_file) {
        unless (-e $config_file) {
            croak "cannot find '$config_file'";
        }
        Log::Log4perl->init($config_file);
    }
    else {
        Log::Log4perl->init( $logger->default_config );
        $logger->log_handle->info("No explicit log config, using default");
    }
    return $logger;
}

sub default_config {
    return \<<EOFC
    log4perl.rootLogger=INFO, SCREEN
    log4perl.appender.SCREEN=Log::Log4perl::Appender::Screen
    log4perl.appender.SCREEN.layout=SimpleLayout
EOFC
}

sub log_handle {
    my $logger = shift;
    Log::Log4perl->get_logger(@_);
}

sub svc_watcher {
    my $logger = shift;
    ## type is 'out' our 'err'
    my ($type, $svc) = @_;

    ## configurable?
    my $logmethod = $type eq 'err' ? 'error' : 'info';
    my $watcher_cb = sub {
        my $msg = shift;
        return unless defined $msg;
        chomp $msg if $msg;
        my $svcname = $svc->name;
        ## for 'S' cspec
        local $CURRENT_SVC_PID = $svc->pid;
        my $log_handle = $logger->log_handle("service.$svcname.$type");
        $log_handle->$logmethod($msg);
        return;
    };
    return $watcher_cb;
}

for my $lvl (qw/trace debug info warn error fatal/) {
    no strict 'refs';
    *{$lvl} = sub {
        local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
        shift->log_handle->$lvl(@_);
    }
}

sub set_configfile {
    my $logger = shift;
    my $configfile = _STRING(shift)
        or return;
    ## reinit
    Log::Log4perl->init($configfile);
    return 1;
}

sub unset {
    my $logger = shift;
    my $what = _STRING(shift);
    return unless $what or $what eq 'configfile';
    return 1;
}

=head1 NAME

ControlFreak::Logger - All about logging

=cut

=head1 SYNOPSIS

=head1 AUTHOR

Yann Kerherve <yannk@cpan.org>

=cut

"zog-zog";
