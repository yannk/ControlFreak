package ControlFreak::Proxy::Process;

use strict;
use warnings;

use AnyEvent();
use AnyEvent::Handle();
use AnyEvent::Util();
use JSON::XS;
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

sub log {
    my $proxy = shift;
    my ($type, $msg) = @_;
    my $pipe = $proxy->{log_hdl} or return;
    $pipe->push_write("$type:-:$msg\n");
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

    if ($proxy->{log_fh}) {
        $proxy->{log_hdl} = AnyEvent::Handle->new(
            fh => $proxy->{log_fh},
        );
    }
    else {
        $proxy->log('err', "No proxy logging");
    }
}

sub process_command {
    my $proxy = shift;
    my $command = shift;

    my $param = try {
        decode_json($command)
    } catch {
        $proxy->log('err', "parse error in command $command: $_");
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
        $proxy->log('err', "couldn't understand command $command: $_");
    }
    return;
}

sub xfer_log {
    my $proxy = shift;
    my ($type, $svc) = @_;
    my $watcher_cb = sub {
        my $msg = shift;
        return unless defined $msg;
        chomp $msg if $msg;
        my $pipe = $proxy->{log_hdl};
        my $name = $svc->{name} || "";
        $pipe->push_write("$type:$name:$msg\n");
        return;
    };
    return $watcher_cb;
}

sub start_service {
    my $proxy = shift;
    my $param = shift;

    my $name = $param->{name};
    my $cmd  = $param->{cmd};

    my $svc  = {};
    $svc->{name} = $name; # intentional repeat
    $proxy->{services}{$name} = $svc;

    $proxy->log('out', "starting $name");

    my %stds = (
        "<"  => "/dev/null",
        ">"  => "/dev/null",
        "2>" => "/dev/null",
    );
    if (my $sockname = $param->{tie_stdin_to}) {
        if ( my $fd = $proxy->{sockets}{$sockname} ) {
            if (open $svc->{fh}, "<&=$fd") {
                $stds{"<"} = $svc->{fh};
            }
            else {
                $proxy->log('err', "couldn't open fd $fd: $!");
            }
        }
        else {
            $proxy->log('err', "'$sockname' not found in proxy");
        }
    }
    unless ($svc->{ignore_stdout}) {
        $stds{">"} = $proxy->xfer_log(out => $svc);
    }
    unless ($svc->{ignore_stderr} ) {
        $stds{"2>"} = $proxy->xfer_log(err => $svc);
    }

    $svc->{cv} = AnyEvent::Util::run_cmd(
        $cmd,
        close_all  => 1,
        '$$' => \$svc->{pid},
        %stds,
    );
    $proxy->send_status('started', $name, $svc->{pid});

    $svc->{cv}->cb( sub {
        my $es = shift()->recv;
        $svc->{cv} = undef;
        my $pid = $svc->{pid};
        $proxy->send_status('stopped', $name, $pid, $es);
        $svc->{pid} = undef;
        delete $proxy->{services}{$name};
    });
}

sub stop_service {
    my $proxy = shift;
    my $param = shift;

    my $svcname = $param->{name};

    my $svc = $proxy->{services}{$svcname};
    unless ($svc) {
        $proxy->log('err', "Oops, I don't know about '$svcname'");
        return;
    }
    $proxy->_stop_service($svc);
}

sub _stop_service {
    my $proxy = shift;
    my $svc = shift;
    my $pid = $svc->{pid};
    $proxy->log('out', "stopping $svc->{name}");
    unless ($pid) {
        $proxy->log('err', "no pid for '$svc->{name}'");
        return;
    }
    kill 'TERM' => $pid;
}

sub send_status {
    my $proxy = shift;
    my ($cmd, $name, $pid, $es) = @_;
    my $string = encode_json({
        status => $cmd,
        name => $name,
        pid => $pid,
        exit_status => $es,
    });

    $proxy->{status_hdl}->push_write("$string\n");
}

sub sockets_from_env {
    my $class = shift;

    my $sockets = {};
    for (keys %ENV) {
        next unless /^_CFK_SOCK_(.+)$/;
        $sockets->{$1} = $ENV{$_};
    }
    return $sockets;
}

sub shutdown {
    my $proxy = shift;
    for my $svc (values %{ $proxy->{services} }) {
        $proxy->_stop_service($svc);
    }
}

1;
