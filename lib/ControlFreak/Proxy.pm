package ControlFreak::Proxy;
use strict;
use warnings;

use AnyEvent::Util();
use Carp;
use JSON::XS;
use Object::Tiny qw{ name cmd pid is_running };
use Params::Util qw{ _ARRAY _STRING };
use POSIX 'SIGTERM';
use Scalar::Util();
use Try::Tiny;

=pod

=head1 NAME

ControlFreak::Proxy - Delegate some control to a secondary process.

=head1 DESCRIPTION

There are some cases where you want some services managed in a special way,
and it makes no sense to implement this in C<ControlFreak> itself.

Indeed, one design trait of B<ControlFreak> is its absolute simplicity, we
don't want to clutter it with features that are only rarely used or that
could make the controller unstable.

One example of that is Memory Sharing. If you have 20 application processes
running on one machine all having the same code running, then there is a
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
    unless ($ctrl->add_proxy($proxy)) {
        $ctrl->log->error("A proxy by that name already exists");
        return;
    }
    Scalar::Util::weaken($proxy->{ctrl});
    return $proxy;
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
        return $proxy->_err(
            %param, "Proxy is not running, not starting service '$name'"
        );
    }
    my $hdl = $proxy->{command_hdl};
    my $descr = {
        command       => 'start',
        cmd           => $svc->cmd,
        name          => $svc->name,
        ignore_stderr => $svc->ignore_stderr,
        ignore_stdout => $svc->ignore_stdout,
        env           => $svc->env,
    };
    my $string = encode_json($descr);
    $hdl->push_write($string);
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
    my $descr = {
        command => 'stop',
        name    => $svc->name,
    };
    my $string = encode_json($descr);
    $hdl->push_write($string);
}

sub unset {
    my $proxy = shift;
    my $attr = shift;
    $proxy->{$attr} = undef;
    return 1;
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

=head2 run

Run the proxy command.

=cut

sub run {
    my $proxy = shift;
    my %param = @_;
    my $err = $param{err_cb} || sub {};
    my $name = $proxy->name;
    return $err->("Proxy '$name' cannot run, it has no command")
        unless $proxy->cmd;

    $proxy->{is_running} = 1;

    ## Command and Status pipes
    my ($cr, $cw) = AnyEvent::Util::portable_pipe;
    my ($sr, $sw) = AnyEvent::Util::portable_pipe;

    AnyEvent::Util::fh_nonblocking($_, 1) for ($sr, $cw);

    my $crno = 3;
    my $swno = 4;

    my $cmd = $proxy->cmd;

    $proxy->{proxy_cv} = AnyEvent::Util::run_cmd(
        $cmd,
        "$crno>"   => $cr,
        "$swno<"   => $sw,
        '$$'       => \$proxy->{pid},
        close_all  => 1,
        on_prepare => sub {}, ## XXX
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
            $proxy->{ctrl}->log->info("proxy '$name' abnormal termination");
        }

        $proxy->has_stopped;
    });
    close $cr;
    close $sw;

    $proxy->{status_fh}   = $sr;
    $proxy->{status_cv}   = AE::io $sr, 0, sub {
        $proxy->read_status;
    };
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
    }
    elsif ($status && $status eq 'stopped') {
        $svc->acknowledge_exit($data->{exit_status});
    }
    else {
        $ctrl->log->fatal( "Unknown status '$status' sent to proxy '$pname'");
    }
}

=head2 services

Return a list of C<ControlFreak::Service> instance under the control of the
proxy.

=cut

=head2 shutdown

Quit the proxy (and consequently stop all related services).

=cut

sub shutdown {
    my $proxy = shift;
    my $name = $proxy->name;
    $proxy->{ctrl}->log->info("shutting down proxy '$name'");
    $proxy->{command_hdl} = undef;

    if (my $pid = $proxy->pid) {
        kill 'TERM', $pid;
    }
    $proxy->{proxy_cv} = undef;
    $proxy->has_stopped;

    $proxy->{status_cv} = undef;
    $proxy->{status_fh} = undef;
    return 1;
}

sub has_stopped {
    my $proxy = shift;
    ## not running anymore, obviously
    $proxy->{is_running} = 0;
    $proxy->{pid} = undef;

    ## no matter what, clean the mess
    for my $svc ($proxy->services) {
        $svc->has_stopped("proxy stopped");
    }
}

1;
