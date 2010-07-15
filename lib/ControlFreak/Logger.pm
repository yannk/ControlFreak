package ControlFreak::Logger;
use strict;
use warnings;

use Carp;
use Log::Log4perl();

use Object::Tiny qw{ config_file };
use Params::Util qw{ _STRING };
use Try::Tiny;

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
    }
    return $logger;
}

sub safe_reinit {
    my $logger = shift;
    unless ($logger->config_file) {
        $logger->warn("Ignored USR1, running with file-less config");
        return;
    }
    $logger->info("Reloading log config");
    try {
        Log::Log4perl->init($logger->config_file);
        $logger->info("Log config reloaded");
    }
    catch {
        ## damn ugly
        warn "reloading config failed";
        use Log::Log4perl::Logger;
        Log::Log4perl::Config->_init(undef, $Log::Log4perl::Config::OLD_CONFIG);
        $logger->error("There is an error in my config. Aborting. ($_)");
    };
}

sub default_config {
    return \<<'EOFC';
log4perl.rootLogger=INFO, ALL
log4perl.appender.ALL=Log::Log4perl::Appender::File
log4perl.appender.ALL.filename=sub { $ENV{CFKD_HOME} . "/cfkd.log" }
log4perl.appender.ALL.mode=append
log4perl.appender.ALL.layout=PatternLayout
# %S = service pid
log4perl.appender.ALL.layout.ConversionPattern=%S %p %L %c - %m%n
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
        return $logger->_svclog($logmethod, $type, $svc, $msg);
    };
    return $watcher_cb;
}

sub _svclog {
    my $logger = shift;
    my ($logmethod, $type, $svc, $msg) = @_;

    my $svcname = $svc->name;
    ## for 'S' cspec
    local $CURRENT_SVC_PID = $svc->pid;
    my $log_handle = $logger->log_handle("service.$svcname.$type");
    chomp $msg if $msg;
    $log_handle->$logmethod($msg);
    return;
}

for my $lvl (qw/trace debug info warn error fatal/) {
    no strict 'refs';
    *{$lvl} = sub {
        local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
        shift->log_handle->$lvl(@_);
    }
}

sub proxy_log {
    my $logger = shift;
    my ($data) = @_;
    my ($type, $proxy, $msg) = @$data;

    my $proxyname = $proxy->name;
    my $logmethod = $type eq 'err' ? 'error' : 'info';

    my $log_handle = $logger->log_handle("proxy.$proxyname.$type");
    chomp $msg if $msg;
    $log_handle->$logmethod($msg);
}

sub proxy_svc_log {
    my $logger = shift;
    my ($data) = @_;
    my ($type, $svc, $msg) = @$data;
    my $logmethod = $type eq 'err' ? 'error' : 'info';
    $logger->_svclog($logmethod, $type, $svc, $msg);
}

sub set_config {
    my $logger = shift;
    my $configfile = _STRING(shift) or return;
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
