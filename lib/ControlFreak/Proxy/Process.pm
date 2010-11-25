package ControlFreak::Proxy::Process;

use strict;
use warnings;

use JSON::XS;
use Try::Tiny;
use POSIX 'SIGTERM';
use IO::Select;

$SIG{PIPE} = 'IGNORE';

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
    $proxy->write_log("$type:-:$msg");
}

sub write_log {
    my $proxy = shift;
    my $fh = $proxy->{log_fh};
    return unless $fh;
    ## check buffer size XXX
    push @{ $proxy->{log_buffer} }, shift;
    $proxy->{write_select}->add($fh);
    return;
}

sub init {
    my $proxy = shift;

    #set_nonblocking($proxy->{$_}) for (qw/command_fh status_fh log_fh/);

    ## where we buffer the writes until our wout fh are ready
    $proxy->{log_buffer}    = [];
    $proxy->{status_buffer} = [];

    ## callbacks
    $proxy->{readers}{ $proxy->{command_fh} } = sub { $proxy->command_cb(@_) };
    $proxy->{writers}{ $proxy->{log_fh}     } = $proxy->{log_buffer}
        if $proxy->{log_fh};
    $proxy->{writers}{ $proxy->{status_fh}  } = $proxy->{status_buffer};

    my $fh = $proxy->{command_fh};
    $proxy->{read_select} = IO::Select->new;
    $proxy->{write_select} = IO::Select->new;
    $proxy->{read_select}->add($proxy->{command_fh});
    $proxy->{write_select}->add($proxy->{log_fh})
        if $proxy->{log_fh};
    $proxy->{write_select}->add($proxy->{status_fh});
}

sub command_cb {
    my $proxy = shift;
    my $command = shift;
    chomp $command;
    $proxy->process_command($_) for (split /\n/, $$command);
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
        chomp $$msg if $$msg;
        my $name = $svc->{name} || "";
        my @msgs = split /\n/, $$msg;
        $proxy->write_log("$type:$name:$_") for @msgs;
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
    $svc->{env} = $param->{env} || {};
    $proxy->{services}{$name} = $svc;

    $proxy->log('out', "starting $name");

    my %stds = ();
    if (my $sockname = $param->{tie_stdin_to}) {
        if ( my $fd = $proxy->{sockets}{$sockname} ) {
            if (open $svc->{fh}, "<&=$fd") {
                $stds{in} = $svc->{fh};
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
        $stds{out} = $proxy->xfer_log(out => $svc);
    }
    unless ($svc->{ignore_stderr} ) {
        $stds{err} = $proxy->xfer_log(err => $svc);
    }
    $proxy->fork_do_cmd(
        $cmd,
        '$$' => \$svc->{pid},
        on_prepare => sub {
            $proxy->prepare_child($svc => $cmd);
        },
        %stds,
    );
    $proxy->send_status('started', $name, $svc->{pid});
    $proxy->verify_pid($svc);
}

sub prepare_child {
    my $proxy = shift;
    my $svc   = shift;
    my $cmd   = shift;

    $SIG{HUP} = $SIG{INT} = $SIG{TERM}
              = $SIG{__WARN__} = $SIG{__DIE__}
              = 'DEFAULT';

    my $name = $svc->{name};
    $0 = "[cfk $name] $cmd";
    unless ($svc->{no_new_session}) {
        my $sessid = POSIX::setsid()
            or print STDERR "cannot create a new session for proxied svc\n";
    }

    $proxy->setup_environment($svc);

    return;
}

sub setup_environment {
    my $proxy = shift;
    my $svc = shift;
    my $env = $svc->{env};
    return unless $env;
    return unless ref $env eq 'HASH';
    while (my ($k, $v) = each %$env) {
        $ENV{$k} = $v;
    }
    $ENV{CONTROL_FREAK_ENABLED} = 1;
    $ENV{CONTROL_FREAK_SERVICE} = $svc->{name};
    return 1;
}

sub fork_do_cmd {
    my $proxy = shift;
    my $cmd = shift;
    my %param = @_;

    my %redir;
    if (my $in = $param{in}) {
        $redir{0} = $in;
    }
    if (my $out = $param{out}) {
        my ($pr, $pw);
        pipe ($pr, $pw);
        $proxy->{readers}{$pr} = $out;
        $proxy->{read_select}->add($pr);
        $redir{1} = $pw;
    }
    if (my $err = $param{err}) {
        my ($pr, $pw);
        pipe ($pr, $pw);
        $proxy->{readers}{$pr} = $err;
        $proxy->{read_select}->add($pr);
        $redir{2} = $pw;
    }

    my $pid = fork;
    if (! defined $pid) {
        $proxy->log('err', "couldn't fork! $!");
        exit -1;
    }
    unless ($pid) {
        ## do the redirection of stds if requested
        ## otherwise reopen to /dev/null
        my $null;
        for (0, 1, 2) {
            if (exists $redir{$_}) {
                POSIX::close($_);
                unless (defined POSIX::dup2(fileno $redir{$_}, $_)) {
                    POSIX::_exit(125);
                }
                POSIX::close($redir{$_});
            }
            else {
                unless ($null) {
                    unless (open $null, "+>/dev/null") {
                        print STDERR "Error opening null: $!";
                        POSIX::_exit(124);
                    }
                }
                POSIX::close($_);
                POSIX::dup2($null, $_);
            }
        }

        if (exists $param{on_prepare}) {
            eval { $param{on_prepare}->(); 1 } or POSIX::_exit(123)
        }

        my $ret = $proxy->run_command($cmd);
        unless (defined $ret) {
            print STDERR "Couldn't do '$cmd': $@";
            exit -1;
        }
        print STDERR "My job is done";
        exit 0;
    }

    ${$param{'$$'}} = $pid
        if $param{'$$'};

    %redir = (); # close child side of the fds
    return;
}

sub run_command {
    my $proxy = shift;
    my $cmd   = shift;

    if (my $code = $proxy->{svc_coderef}) {
        ## ignore command alltogether
        return $code->();
    }
    return do $cmd;
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
    kill -(SIGTERM), getpgrp($pid);
}

sub send_status {
    my $proxy = shift;
    my ($cmd, $name, $pid, $es) = @_;
    my $fh = $proxy->{status_fh}
        or return;

    my $string = encode_json({
        status => $cmd,
        name => $name,
        pid => $pid,
        exit_status => $es,
    });

    push @{ $proxy->{status_buffer} }, $string;
    ## now watch for writability.
    $proxy->{write_select}->add($fh);
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

sub child_exit {
    my $proxy = shift;
    my ($pid, $status) = @_;

    my ($svc) = grep { $_->{pid} == $pid }
                grep { $_->{pid} }
                values %{ $proxy->{services} };

    unless ($svc) {
        $proxy->log(err => "Blacklisting yet unknown pid $pid");
        $proxy->blacklist_pid($pid, $status);
        return;
    }
    $proxy->send_status('stopped', $svc->{name}, $pid, $status);
    $svc->{pid} = undef;
    delete $proxy->{services}{ $svc->{name} };
}

sub blacklist_pid {
    my $proxy = shift;
    my ($pid, $status) = @_;
    $proxy->{pid_blacklist}->{$pid} = { time => time, exit_status => $status };
}

sub verify_pid {
    my $proxy = shift;
    my ($svc) = @_;
    for my $pid (keys %{ $proxy->{pid_blacklist} }) {
        my $bl = $proxy->{pid_blacklist}{$pid};
        my $es = $bl->{exit_status};
        if ($svc->{pid} == $pid) {
            $proxy->send_status('stopped', $svc->{name}, $pid, $es);
            $svc->{pid} = undef;
            next;
        }
        my $time = $bl->{time};
        if (time - $time > 5) {
            $proxy->log(err => "Oops pid disappeared: $pid");
        }
    }
    return;
}

sub run {
    my $proxy = shift;

    $SIG{CHLD} = sub {
        ## Ideally we woudn't do much in there, to return quickly
        while ((my $pid = waitpid -1, &POSIX::WNOHANG) > 0) {
            $proxy->child_exit($pid, $?);
        }
    };

    my $rs = $proxy->{read_select};
    my $ws = $proxy->{write_select};
    while (1) {
        while (my ($rout, $wout) = IO::Select->select($rs, $ws, undef)) {
            for my $fh (@$rout) {
                my $len = sysread($fh, my $buf, 16*1024);
                if ($len <= 0) {
                    $rs->remove($fh);
                    close $fh;
                }
                $proxy->dispatch_read($fh, \$buf);
            }
            for my $fh (@$wout) {
                $proxy->dispatch_write($fh);
            }
        }
        # it would be nice to have more log channels
        #$proxy->log(debug => "select() interrupted with $!");
    }
}

sub dispatch_read {
    my $proxy = shift;
    my ($fh, $dataref) = @_;
    my $cb = $proxy->{readers}->{$fh};
    unless ($cb) {
        $proxy->log(err => "cannot find callback for reader");
        return;
    }
    $cb->($dataref);
}

sub dispatch_write {
    my $proxy = shift;
    my ($fh) = @_;
    if (! exists $proxy->{writers}{$fh} ) {
        $proxy->log(err => "cannot find the buffer for writer");
        return;
    }
    my $buf = $proxy->{writers}{$fh} || [];
    my $ws = $proxy->{write_select};
    while (@$buf) {
        my $data = shift @$buf;
        my $len = syswrite $fh, "$data\n";
        if (! defined $len or $len <= 0) {
            $ws->remove($fh);
            close $fh;
            last;
        }
    }
    ## We don't need to look for writability for now
    $ws->remove($fh);
}

sub set_nonblocking {
    require Fcntl;
    fcntl $_[0], &Fcntl::F_SETFL, &Fcntl::O_NONBLOCK;
}

1;
