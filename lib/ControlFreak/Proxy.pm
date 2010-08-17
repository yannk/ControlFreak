package ControlFreak::Proxy;
use strict;
use warnings;

use AnyEvent::Util();
use Carp;
use ControlFreak::Util;
use Fcntl qw(F_GETFD F_SETFD FD_CLOEXEC);
use JSON::XS;
use Object::Tiny qw{ name cmd pid is_running env auto };
use Params::Util qw{ _ARRAY _STRING };
use POSIX 'SIGTERM';
use Scalar::Util();
use Try::Tiny;

=pod

=head1 NAME

ControlFreak::Proxy - Delegate some control to an intermediary process.

=head1 DESCRIPTION

There are some cases where you want some services managed in a special way,
and it makes no sense to implement this in C<ControlFreak> itself.

Indeed, one design trait of B<ControlFreak> is its absolute simplicity, we
don't want to clutter it with features that are only rarely used or that
could make the controller unstable.

One example of that is Memory Sharing. If you have 20 application processes
running on one machine all having the same code running, there is a
memory benefit into making sure the app is loaded in the parent process
of all these applications. Indeed, it would allow all children to initially
share parent code and thus potentially reduce the memory footprint of the
application by quite a while, maybe. But, it's out of question for the
C<controller> to load that code in its own memory. A better solution is to use
a C<ControlFreak::Proxy> separate process that will:

=over 4

=item * load the application code once and for all

=item * take commands from the main C<controller> (over pipes)

=item * fork children when instructed, that exec some user defined commands

=back

=head1 SYNOPSIS

  $proxy = ControlFreak::Proxy->new(
      ctrl => $ctrl,
      cmd  => '/usr/bin/cfk-share-mem-proxy.pl --preload Some::Module',

  );
  $proxy->add_service($svc);
  $proxy->destroy_service($svc);
  $proxy->run;
  $proxy->start_service($svc);
  $proxy->stop_service($svc);
  @list = $proxy->services;
  $proxy->shutdown;
  $proxy->is_running;

=head1 METHODS

=head2 new(%param)

=cut

sub new {
    my $class = shift;
    my %param = @_;

    my $ctrl = $param{ctrl};
    unless ($ctrl) {
        warn "Proxy creation attempt without ctrl";
        return;
    }

    unless ($param{name}) {
        $ctrl->log->error("Proxy creation attempt without a name");
        return;
    }

    my $proxy = $class->SUPER::new(%param);
    $proxy->{ctrl} = $ctrl;
    $proxy->{servicemap} = {};
    $proxy->{env}  ||= {};
    unless (defined $param{auto}) {
        $proxy->{auto} = 1; # proxy is 'auto' by default
    }
    unless ($ctrl->add_proxy($proxy)) {
        $ctrl->log->error("A proxy by that name already exists");
        return;
    }
    Scalar::Util::weaken($proxy->{ctrl});
    return $proxy;
}

=head2 status_as_text

Returns the status of the proxy, including its eventual pid in one line of
text, where the following fields are seperated with tabs:

=over 4

=item * name

=item * status ('up' or 'down')

=item * pid, if proxy is up

=back

=cut

sub status {
    my $proxy = shift;
    return $proxy->is_running ? "up" : "down";
}

sub status_as_text {
    my $proxy = shift;
    return join "\t", map { $proxy->$_ || "" } qw/name status pid/;
}

sub _err { ControlFreak::Util::error(@_) }

=head2 services

Returns a list of L<ControlFreak::Service> objects related to the
proxy.

=cut
sub services {
    my $proxy = shift;
    return values %{ $proxy->{servicemap} };
}

=head2 add_service($svc)

Declares a service under the control of the proxy.

=cut

sub add_service {
    my $proxy = shift;
    my $svc   = shift;
    $proxy->{servicemap}->{$svc->name} = $svc;
    $svc->assign_proxy($proxy);
    return 1;
}

=head2 start_service

Given a L<ControlFreak::Service>, check that it is effectively
under the control of a L<ControlFreak::Proxy> object and contact the
later to instruct it to start the service on our behalf.

=cut

sub start_service {
    my $proxy = shift;
    my %param = @_;

    my $svc = $param{service};

    my $name = $svc->name;
    unless ($svc->{proxy} && $svc->{proxy} eq $proxy) {
        return $proxy->_err(
            %param, "Cannot start svc '$name': inappropriate proxy"
        );
    }
    unless ($proxy->is_running) {
        if ($proxy->auto) {
            $proxy->run;
        }
        else {
            return $proxy->_err(
                %param, "Proxy is not running, not starting service '$name'"
            );
        }
    }
    my $hdl = $proxy->{command_hdl};
    my $descr = {
        command        => 'start',
        cmd            => $svc->cmd,
        name           => $svc->name,
        ignore_stderr  => $svc->ignore_stderr,
        ignore_stdout  => $svc->ignore_stdout,
        env            => $svc->env,
        tie_stdin_to   => $svc->tie_stdin_to,
        no_new_session => $svc->no_new_session,
    };
    my $string = encode_json($descr);
    $hdl->push_write("$string\n");
}

sub stop_service {
    my $proxy = shift;
    my %param = @_;
    my $svc = $param{service};

    my $pname = $proxy->name;
    my $sname = $svc->name;
    return $proxy->_err(%param, "proxy '$pname' not running for '$sname'")
        unless $proxy->is_running;

    my $hdl = $proxy->{command_hdl};
    unless ($hdl) {
        ## TODO: cleanup?
        $proxy->{ctrl}->log->error("proxy '$pname' is gone");
        return;
    }
    my $descr = {
        command => 'stop',
        name    => $svc->name,
    };
    my $string = encode_json($descr);
    $hdl->push_write("$string\n");
}

sub unset {
    my $proxy = shift;
    my $attr = shift;
    $proxy->{$attr} = undef;
    return 1;
}

sub setup_environment {
    my $proxy = shift;
    my $env = $proxy->env;
    return unless $env;
    return unless ref $env eq 'HASH';
    while (my ($k, $v) = each %$env) {
        $ENV{$k} = $v;
    }
    return 1;
}

sub set_add_env {
    my $proxy = shift;
    my $value = _STRING($_[0]) or return;
    my ($key, $val) = split /=/, $value, 2;
    $proxy->{ctrl}->log->debug( "Setting ENV{$key} to '$val'" );
    $proxy->add_env($key, $val);
}

=head2 add_env($key => $value)

Adds an environment key, value pair to the proxy

=cut

sub add_env {
    my $proxy = shift;
    my ($key, $value) = @_;
    $proxy->env->{$key} = $value;
    return 1;
}

=head2 clear_env()

Resets proxy environment to empty.

=cut

sub clear_env {
    my $proxy = shift;
    $proxy->{env} = {};
}

sub set_cmd {
    my $value = (ref $_[1] ? _ARRAY($_[1]) : _STRING($_[1])) or return;
    shift->_set('cmd', $value);
}

sub set_cmd_from_con {
    my $proxy = shift;
    my $value = shift;
    return $proxy->unset('cmd') unless defined $value;
    if ($value =~ /^\[/) {
        $value = try { decode_json($value) }
        catch {
            my $error = $_;
            $proxy->{ctrl}->log->error("Invalid JSON: $error");
            return;
        };
    }
    return $proxy->set_cmd($value);
}

sub set_desc {
    my $value = _STRING($_[1]) or return;
    $value =~ s/[\n\r\t\0]+//g; ## desc should be one line
    shift->_set('desc', $value);
}

sub set_noauto {
    my $value = _STRING($_[1]);
    return unless defined $value;
    shift->_set('auto', !$value);
}

sub _set {
    my $proxy = shift;
    my ($attr, $value) = @_;

    my $old = $proxy->$attr;

    my $v = defined $value ? $value : "~";
    local $Data::Dumper::Indent = 0;
    local $Data::Dumper::Terse = 1;
    if (ref $v) {
        $v = Data::Dumper::Dumper($v);
    }
    if ($old) {
        my $oldv = defined $old ? $old : "~";
        $oldv = Data::Dumper::Dumper($oldv) if ref $oldv;
        $proxy->{ctrl}->log->debug( "Changing $attr from '$oldv' to '$v'" );
    }
    else {
        $proxy->{ctrl}->log->debug( "Setting $attr to '$v'" );
    }
    $proxy->{$attr} = $value;
    return 1;
}


## open in the proxy process before exec
sub prepare_child_fds {
    my $proxy = shift;
    my ($cr, $sw, $lw) = @_;

    $proxy->no_close_on_exec($_) for ($cr, $sw, $lw);

    $ENV{_CFK_COMMAND_FD} = fileno $cr;
    $ENV{_CFK_STATUS_FD}  = fileno $sw;
    $ENV{_CFK_LOG_FD}     = fileno $lw;

    $proxy->write_sockets_to_env;
}

sub write_sockets_to_env {
    my $proxy = shift;

    my $ctrl  = $proxy->{ctrl};
    for my $socket ($ctrl->sockets) {
        my $fh = $socket->fh or next;

        $proxy->no_close_on_exec($fh);
        my $prefix = "_CFK_SOCK_";
        my $name = $prefix . $socket->name;
        $ENV{$name} = fileno $fh;
    }
}

sub no_close_on_exec {
    my $proxy = shift;
    my $fh =  shift;
    my $flags = fcntl($fh, F_GETFD, 0);
    fcntl($fh, F_SETFD, $flags & ~FD_CLOEXEC);
}

=head2 run

Runs the proxy command.

=cut

sub run {
    my $proxy = shift;
    my %param = @_;
    my $err = $param{err_cb} ||= sub {};

    my $name = $proxy->name;
    return $proxy->_err(%param, "Proxy '$name' can't run: no command")
        unless $proxy->cmd;

    $proxy->{is_running} = 1;

    ## Command, Status and Log pipes
    my ($cr, $cw) = AnyEvent::Util::portable_pipe;
    my ($sr, $sw) = AnyEvent::Util::portable_pipe;
    my ($lr, $lw) = AnyEvent::Util::portable_pipe;

    AnyEvent::Util::fh_nonblocking($_, 1) for ($sr, $cw, $lr);

    my $cmd = $proxy->cmd;

    ## XXX redir std /dev/null
    $proxy->{proxy_cv} = AnyEvent::Util::run_cmd(
        $cmd,
        '$$'       => \$proxy->{pid},
        close_all  => 0,
        on_prepare => sub {
            $proxy->setup_environment;
            $proxy->prepare_child_fds($cr, $sw, $lw);
        },
    );

    $proxy->{proxy_cv}->cb( sub {
        my $es = shift()->recv;
        $proxy->{proxy_cv} = undef;
        $proxy->{pid} = undef;
        $proxy->{exit_status} = $es;
        my $name = $proxy->name;
        my $state;
        if (POSIX::WIFEXITED($es) && !POSIX::WEXITSTATUS($es)) {
            $proxy->{ctrl}->log->info("proxy '$name' exited");
        }
        elsif (POSIX::WIFSIGNALED($es) && POSIX::WTERMSIG($es) == SIGTERM) {
            $proxy->{ctrl}->log->info("proxy '$name' gracefully killed");
        }
        else {
            my $r = ControlFreak::Util::exit_reason($es);
            $proxy->{ctrl}->log->info(
                "proxy '$name' abnormal termination " . $r
            );
        }

        $proxy->has_stopped;
    });
    close $cr;
    close $sw;
    close $lw;

    $proxy->{status_fh}   = $sr;
    $proxy->{log_fh}      = $lr;
    $proxy->{status_cv}   = AE::io $sr, 0, sub { $proxy->read_status };
    $proxy->{log_cv}      = AE::io $lr, 0, sub { $proxy->read_log    };

    $proxy->{command_hdl} = AnyEvent::Handle->new(
        fh => $cw,
        on_error => sub {
            my ($h, $fatal, $message) = @_;
            $proxy->{ctrl}->log->error($message || "unknown proxy error");
            if ($fatal) {
                $proxy->{ctrl}->log->error("Proxy fatal error");
                $proxy->shutdown;
                undef $h;
            }
        },
    );
}

=head2 shutdown

Quits the proxy (and consequently stops all related services).

=cut

sub shutdown {
    my $proxy = shift;
    my %param = @_;

    my $ok  = $param{ok_cb} ||= sub {};
    my $err = $param{err_cb} ||= sub {};

    my $name = $proxy->name;
    $proxy->{ctrl}->log->info("shutting down proxy '$name'");
    $proxy->{command_hdl} = undef;

    if (my $pid = $proxy->pid) {
        kill 'TERM', $pid;
    }
    ## eventually mark it has dead
    $proxy->{shutdown_cv} = AE::timer 3, 0, sub { $proxy->has_stopped(1) };

    $ok->();
    return 1;
}

sub read_log {
    my $proxy = shift;
    my $log_fh = $proxy->{log_fh} or return;
    my @logs;
    while (<$log_fh>) {
        push @logs, $_;
    }
    for (@logs) {
        next unless $_;
        $proxy->process_log($_);
    }
    return;
}

sub read_status {
    my $proxy = shift;
    my $status_fh = $proxy->{status_fh} or return;
    my @statuses;
    while (<$status_fh>) {
        push @statuses, $_;
    }
    for (@statuses) {
        next unless $_;
        $proxy->process_status($_);
    }
    return;
}

sub process_status {
    my $proxy = shift;
    my $json_data = shift;

    my $ctrl = $proxy->{ctrl};
    $ctrl->log->debug("Got a new status: $json_data");

    my $data = decode_json($json_data);

    my $pname  = $proxy->name;
    my $name   = $data->{name} || "";
    my $svc    = $proxy->{servicemap}{$name};
    my $status = $data->{status};

    if ($status && $status eq 'started') {
        my $pid = $data->{pid};
        unless ($pid) {
            $ctrl->log->fatal("Started '$name' without pid!");
        }
        $svc->assign_pid( $pid );
        $svc->set_check_running_state_timer;
    }
    elsif ($status && $status eq 'stopped') {
        $svc->acknowledge_exit($data->{exit_status});
        if ($proxy->auto) {
            my @up = grep { $_->is_up } $proxy->services;
            unless (@up) {
                $proxy->shutdown;
            }
        }
    }
    else {
        $ctrl->log->fatal( "Unknown status '$status' sent to proxy '$pname'");
    }
}

sub process_log {
    my $proxy = shift;
    my $log_data = shift;

    my $ctrl = $proxy->{ctrl};
    my ($type, $svcname, $msg) = split ':', $log_data, 3;

    if ($svcname && $svcname eq '-') {
        ## this is a proxy log
        $ctrl->log->proxy_log([ $type, $proxy, $msg ]);
        return;
    }
    my $svc = $ctrl->service($svcname);
    unless ($svc) {
        $svcname ||= "";
        chomp $msg;
        $ctrl->log->error("Cannot find svc '$svcname' for proxy log. [$msg]");
        return;
    }
    $ctrl->log->proxy_svc_log([ $type, $svc, $msg ]);
    return;
}

=head2 has_stopped

Called when the proxy has exited. It performs a number
of cleaning tasks.

=cut

sub has_stopped {
    my $proxy = shift;
    my $finally = shift;

    ## ignore if already dead
    return unless $proxy->{is_running};

    ## cancel timer
    $proxy->{shutdown_cv} = undef;

    if ($finally) {
        my $pname = $proxy->name;
        $proxy->{ctrl}->log->warn("Proxy '$pname' didn't clean after itself?");
    }
    ## not running anymore, obviously
    $proxy->{is_running} = 0;
    $proxy->{pid} = undef;

    $proxy->{proxy_cv} = undef;
    $proxy->{status_cv} = undef;
    $proxy->{status_fh} = undef;
    $proxy->{log_cv}    = undef;
    $proxy->{log_fh}    = undef;

    ## no matter what, clean the mess
    for my $svc ($proxy->services) {
        $svc->has_stopped("proxy stopped");
    }
}

1;
