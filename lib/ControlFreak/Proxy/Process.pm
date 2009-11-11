package ControlFreak::Proxy::Process;

use strict;
use warnings;

use AnyEvent();
use AnyEvent::Handle();
use AnyEvent::Util();
use JSON::XS;
use Try::Tiny;
use POSIX 'SIGTERM';

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

    set_nonblocking($proxy->{$_}) for (qw/command_fh status_fh log_fh/);

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
        my @msgs = split /\n/, $msg;
        $pipe->push_write("$type:$name:$_\n") for @msgs;
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
    $svc->{cv} = $proxy->fork_do_cmd(
        $cmd,
        close_all => 1,
        '$$' => \$svc->{pid},
        on_prepare => sub {
            $proxy->prepare_child($svc => $cmd);
        },
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

sub prepare_child {
    my $proxy = shift;
    my $svc   = shift;
    my $cmd   = shift;

    $SIG{HUP} = $SIG{INT} = $SIG{TERM}
              = $SIG{__WARN__} = $SIG{__DIE__}
              = 'DEFAULT';

    my $name = $svc->{name};
    $0 = "[cfk $name] $cmd";
    my $sessid = POSIX::setsid()
        or $proxy->log(err => "cannot create a new session for proxied svc");
    return;
}

sub fork_do_cmd {
    my $proxy = shift;
    my $cmd = shift;
    require POSIX;
    my $cv = AE::cv;

    my %arg;
    my %redir;
    my @exe;

    while (@_) {
        my ($type, $ob) = splice @_, 0, 2;

        my $fd = $type =~ s/^(\d+)// ? $1 : undef;

        if ($type eq ">") {
            $fd = 1 unless defined $fd;

            if (defined eval { fileno $ob }) {
                $redir{$fd} = $ob;
            } elsif (ref $ob) {
                my ($pr, $pw) = AnyEvent::Util::portable_pipe;
                $cv->begin;
                my $w; $w = AE::io $pr, 0,
                "SCALAR" eq ref $ob
                ? sub {
                    sysread $pr, $$ob, 16384, length $$ob
                        and return;
                    undef $w; $cv->end;
                }
                : sub {
                    my $buf;
                    sysread $pr, $buf, 16384
                        and return $ob->($buf);
                    undef $w; $cv->end;
                    $ob->();
                }
                ;
                $redir{$fd} = $pw;
            } else {
                push @exe, sub {
                    open my $fh, ">", $ob
                        or POSIX::_exit (125);
                    $redir{$fd} = $fh;
                };
            }

        } elsif ($type eq "<") {
            $fd = 0 unless defined $fd;

            if (defined eval { fileno $ob }) {
                $redir{$fd} = $ob;
            } elsif (ref $ob) {
                my ($pr, $pw) = AnyEvent::Util::portable_pipe;
                $cv->begin;

                my $data;
                if ("SCALAR" eq ref $ob) {
                    $data = $$ob;
                    $ob = sub { };
                } else {
                    $data = $ob->();
                }

                my $w; $w = AE::io $pw, 1, sub {
                    my $len = syswrite $pw, $data;

                    if ($len <= 0) {
                        undef $w; $cv->end;
                    } else {
                        substr $data, 0, $len, "";
                        unless (length $data) {
                            $data = $ob->();
                            unless (length $data) {
                                undef $w; $cv->end
                            }
                        }
                    }
                };

                $redir{$fd} = $pr;
            } else {
                push @exe, sub {
                    open my $fh, "<", $ob
                        or POSIX::_exit (125);
                    $redir{$fd} = $fh;
                };
            }

        } else {
            $arg{$type} = $ob;
        }
    }

    my $pid = fork;
    if (! defined $pid) {
        $proxy->log('err', "couldn't fork! $!");
        exit -1;
    }
    unless ($pid) {
        # step 1, execute
        $_->() for @exe;

        # step 2, move any existing fd's out of the way
        # this also ensures that dup2 is never called with fd1==fd2
        # so the cloexec flag is always cleared
        my (@oldfh, @close);
        for my $fh (values %redir) {
            push @oldfh, $fh; # make sure we keep it open
            $fh = fileno $fh; # we only want the fd

            # dup if we are in the way
            # if we "leak" fds here, they will be dup2'ed over later
            defined ($fh = POSIX::dup ($fh)) or POSIX::_exit (124)
            while exists $redir{$fh};
        }

        # step 3, execute redirects
        while (my ($k, $v) = each %redir) {
            defined POSIX::dup2 ($v, $k)
                or POSIX::_exit (123);
        }

        # step 4, close everything else, except 0, 1, 2
        if ($arg{close_all}) {
            AnyEvent::Util::close_all_fds_except 0, 1, 2, keys %redir
        } else {
            POSIX::close ($_)
            for values %redir;
        }

        eval { $arg{on_prepare}(); 1 } or POSIX::_exit (123)
        if exists $arg{on_prepare};

        my $ret = do $cmd;
        unless (defined $ret) {
            print STDERR "Couldn't do '$cmd': $!";
            exit -1;
        }
        print STDERR "My job is done";
        exit 0;
    }

    ${$arg{'$$'}} = $pid
        if $arg{'$$'};

    %redir = (); # close child side of the fds

    my $status;
    $cv->begin (sub { shift->send ($status) });
    my $cw; $cw = AE::child $pid, sub {
        $status = $_[1];
        undef $cw; $cv->end;
    };

    $cv;
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

sub run {
    AE::cv->recv;
}

sub set_nonblocking {
    require Fcntl;
    fcntl $_[0], &Fcntl::F_SETFL, &Fcntl::O_NONBLOCK;
}

1;
