package ControlFreak::Proxy::Process;

use strict;
use warnings;

use AnyEvent();
use AnyEvent::Handle();
use AnyEvent::Util();
use JSON::Any;
use Try::Tiny;

=head1 NAME

ControlFreak::Proxy::Process - The Perl implementation of a proxy process.

=head1 DESCRIPTION

This class is used by L<cfk-share-mem-proxy.pl> to implement the controlling
process of proxied services.

=cut

sub new {
    my $class = shift;
    my %param = @_;
    my $proxy = bless { %param }, ref $class || $class;
    $proxy->init;
    return $proxy;
}

sub init {
    my $proxy = shift;
    ## install the command watcher
    my $fh = $proxy->{command_fh};
    $proxy->{command_watcher} = AnyEvent->io(
        fh => $fh,
        poll => 'r',
        cb => sub {
            my @commands;
            while (<$fh>) {
                chomp;
                push @commands, $_;
            }
            $proxy->process_command($_) for @commands;
        },
    );

    $proxy->{status_hdl} = AnyEvent::Handle->new(
        fh => $proxy->{status_fh},
        #on_eof
        #on_error
    );
}

sub process_command {
    my $proxy = shift;
    my $command = shift;

    my $json = JSON::Any->new;
    my $param = try {
        $json->decode($command)
    } catch {
        print STDERR "parse error in command $command: $_\n";
        return;
    };
    my $c = $param->{command};
    if ($c && $c eq 'start') {
        $proxy->start_service($param);
    }
    elsif ($c && $c eq 'stop') {
        $proxy->stop_service($param);
    }
    else {
        print STDERR "couldn't understand command $command: $_\n";
    }
}

sub start_service {
    my $proxy = shift;
    my $param = shift;

    my $name = $param->{name};
    my $cmd  = $param->{cmd};
    my $svc  = $proxy->{services}{$name};
    $svc->{cv} = AnyEvent::Util::run_cmd(
        $cmd,
        '$$' => \$svc->{pid},
    );
    $proxy->send_status('started', $name, $svc->{pid});

    $svc->{cv}->cb( sub {
        my $es = shift()->recv;
        $svc->{cv} = undef;
        my $pid = $svc->{pid};
        $proxy->send_status('stopped', $name, $pid, $es);
        $svc->{pid} = undef;
    });
}

sub send_status {
    my $proxy = shift;
    my ($cmd, $name, $pid, $es) = @_;
    my $json = JSON::Any->new;
    my $string = $json->encode({
        status => $cmd,
        name => $name,
        pid => $pid,
        exit_status => $es,
    });

    $proxy->{status_hdl}->push_write($string);
}

1;
