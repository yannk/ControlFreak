package ControlFreak::Logger;
use strict;
use warnings;

use Carp;
use Log::Log4perl();
use Sub::Uplevel;

use Object::Tiny qw{ config_file };

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

sub default_config {
    return \<<EOFC
    log4perl.rootLogger=INFO, SCREEN
    log4perl.appender.SCREEN=Log::Log4perl::Appender::Screen
    log4perl.appender.SCREEN.layout=PatternLayout
    log4perl.appender.SCREEN.layout.ConversionPattern=%m%n
EOFC
}

sub log_handle { Log::Log4perl->get_logger(@_) }

sub svc_watcher {
    my $logger = shift;
    ## type is 'out' our 'err'
    my ($type, $svcname) = @_;

    ## configurable?
    my $logmethod = $type eq 'err' ? 'error' : 'info';
    my $watcher_cb = sub {
        my $msg = shift;
        return unless defined $msg;
        chomp $msg if $msg;
        my $log_handle = $logger->log_handle("service.$svcname.$type");
        $log_handle->$logmethod($msg);
        return;
    };
    return $watcher_cb;
}

{
    no strict 'refs';
    for my $lvl (qw/trace debug info warn error fatal/) {
        *$lvl = sub {
            my $logger = shift;
            my $handle = $logger->log_handle;
            my $class  = ref $handle;
            uplevel 1, \&{"$class\::$lvl"}, @_;
        };
    }
}

=head1 NAME

ControlFreak::Logger - All about logging

=cut

=head1 SYNOPSIS

=head1 AUTHOR

Yann Kerherve <yannk@cpan.org>

=cut

"zog-zog";
