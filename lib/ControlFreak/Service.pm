package ControlFreak::Service;
use strict;
use warnings;

use AnyEvent '5.202';
use AnyEvent::Util();
use AnyEvent::Handle();
use Carp;
use Data::Dumper();
use Params::Util qw{ _NUMBER _STRING _IDENTIFIER _ARRAY _POSINT };
use POSIX 'SIGTERM';

use constant DEFAULT_START_SECS  => 1;
use constant DEFAULT_MAX_RETRIES => 8;
use constant BASE_BACKOFF_DELAY  => 0.3;

use Object::Tiny qw{
    name
    desc

    state
    pid
    start_time
    stop_time
    running_cmd

    cmd
    env
    cwd
    tags
    pipe_stdin
    ignore_stderr
    ignore_stdout
    start_secs
    stopwait_secs
    respawn_on_fail
    respawn_on_stop
    respawn_max_retries
    user
    group
    priority
};

=encoding utf-8

=head1 NAME

ControlFreak::Service - Object representation of a service.

=head1 SYNOPSIS

    my $mc = ControlFreak::Service->new(
        name => "memcached",
        desc => "you should have this one...",
        ignore_stderr => 1,
        cmd => "/usr/bin/memcached",
    );

    my $fcgisock = $ctrl->socketmap->{fcgi};
    my $web = ControlFreak::Service->new(
        name => "fcgi",
        desc => "I talk http",
        pipe_stdin => $fcgisock,
        cmd => "/usr/bin/plackup -a MyApp -s FCGI",
    );
    $web->up;
    $web->start;
    $web->stop;

    ## A service can mutate
    $web->add_tag('prod');

    ## all set_* accessors are callable from Commands
    $web->set_cmd("/usr/bin/plackup -a MyNewApp");
    $web->set_ignore_stderr(0);
    # ...

    $web->running_cmd;

=head1 DESCRIPTION

This allow manipulation of a service and its state.

=head1 METHODS

=head2 new(%param)

constructor.

=cut

sub new {
    my $svc = shift->SUPER::new(@_);
    my %param = @_;

    ## validate the service name
    unless (_IDENTIFIER($svc->name)) {
        return;
    }

    ## sensible default
    $svc->{respawn_on_fail} = 1
        unless exists $svc->{respawn_on_fail};

    $svc->{respawn_max_retries} = DEFAULT_MAX_RETRIES
        unless exists $svc->{respawn_max_retries};

    $svc->{ctrl} = $param{ctrl}
        or croak "Service requires a controller";
    return $svc;
}

=head2 is_fail

return true if the state is 'failed'

=cut

sub is_fail {
    my $state = shift->state || "";
    return $state eq 'fail';
}

=head2 is_backoff

return true if the state is 'backoff'

=cut

sub is_backoff {
    my $state = shift->state || "";
    return $state eq 'backoff';
}

=head2 is_fatal

return true if the state is 'fatal'

=cut

sub is_fatal {
    my $state = shift->state || "";
    return $state eq 'fatal';
}

=head2 is_running

return true if the state is 'runnnig'

=cut

sub is_running {
    my $state = shift->state || "";
    return $state eq 'running';
}

=head2 is_starting

return true if the state is 'starting'

=cut

sub is_starting {
    my $state = shift->state || "";
    return $state eq 'starting';
}

=head2 is_stopping

return true if the state is 'stopping'

=cut

sub is_stopping {
    my $state = shift->state || "";
    return $state eq 'stopping';
}

=head2 is_stopped

return true is service is stopped

=cut

sub is_stopped {
    my $state = shift->state || "";
    return $state eq 'stopped';
}

=head2 is_up

return true is service is up

=cut

sub is_up {
    my $svc = shift;
    my $state = $svc->state || "";
    return 0 unless $state =~ /^(?:running|starting|stopping)$/;

    ## just in case, verify...
    return 0 unless defined $svc->{child_cv};
    return 0 unless defined $svc->pid;
    return 1;
}

=head2 is_down

return true unless service is up

=cut

sub is_down {
    return !shift->is_up;
}

=head2 fail_reason

Returns a string with the reason of the failure, or undef.

=cut

sub fail_reason {
    my $svc = shift;
    return unless $svc->is_fail;
    my $status = $svc->{exit_status};

    my $exit_status = POSIX::WEXITSTATUS($status);
    my $signal      = POSIX::WTERMSIG($status);

    my ($exit, $sig);
    if (POSIX::WIFEXITED($status)) {
        $exit = $exit_status
              ? "Exited with error $exit_status"
              : "Exited successfuly";
    }

    $sig = "Received signal $signal" if POSIX::WIFSIGNALED($status);
    return join " - ", grep { $_ } ($exit, $sig);
}

=head2 stop(%param)

Initiate service shutdown.

params are:

=over 4

=item * ok_cb

A callback called when shutdown has been initiated successfuly. Note that it
doesn't mean that the service is successfuly stopped, just that nothing
prevented the shutdown sequence.

Optional.

=item * err_cb

Called with a text reason when the stop request couldn't be initiated properly.

Optional.

=back

=cut

sub stop {
    my $svc = shift;
    my %param = @_;
    my $err = $param{err_cb} || sub {};
    my $ok  = $param{ok_cb}  || sub {};

    my $svcname = $svc->name || "unnamed service";
    if ($svc->is_down) {
        $err->("Service '$svcname' is already down");
        return;
    }
    unless ($svc->pid) {
        $err->("Service '$svcname' lost its pid");
        return;
    }
    ## there is a slight race condition here, since the child
    ## might have died just before we send the TERM signal, but
    ## we trust the kernel not to reallocate the pid in the meantime
    kill 'TERM', $svc->pid;
    $svc->{stop_time} = time;
    $svc->{start_time} = undef;
    $svc->{state} = 'stopping';
    $ok->();
    return 1;
}

=head2 start(%param)

Initiate service startup.

params are:

=over 4

=item * ok_cb

A callback called when startup has been initiated successfuly. Note that it
doesn't mean that the service is successfuly running, just that nothing
prevented the startup.

Optional.

=item * err_cb

A callback called when an error occured during startup (For instance
if the service is already started), the reason for the failure is
passed as the first argument of the callback if is known.

Optional.

=back

=cut

sub start {
    my $svc = shift;
    my %param = @_;
    my $err = $param{err_cb} || sub {};
    my $ok  = $param{ok_cb}  || sub {};

    my $svcname = $svc->name || "unnamed service";
    if ($svc->is_up) {
        $err->("Service '$svcname' is already up");
        return;
    }
    my $cmd = $svc->cmd;
    unless ($cmd) {
        $err->("Service '$svcname' has no known command");
        return;
    }

    $svc->{start_time} = time;
    $svc->{stop_time} = undef;
    $svc->{state} = 'starting';
    $svc->_run_cmd;
    my $start_secs = $svc->start_secs || DEFAULT_START_SECS;
    $svc->{start_cv} =
        AE::timer $start_secs, 0, sub { $svc->_check_running_state };

    $ok->();
    return 1;
}

sub _check_running_state {
    my $svc = shift;
    $svc->{start_cv} = undef;
    return unless $svc->is_starting;
    $svc->{ctrl}->log->debug("Now setting the service as running");
    $svc->{state} = 'running';
    $svc->{backoff_retry} = undef;
}

sub _backoff_restart {
    my $svc = shift;
    $svc->{backoff_cv} = undef;
    return unless $svc->is_backoff;
    my $n = $svc->{backoff_retry} + 1;
    my $s = $svc->name;
    $svc->{ctrl}->log->info("restarting $s [attempt: $n]");
    $svc->start;
    return;
}

sub _exponential_backoff_delay {
    my $svc   = shift;
    my $retry = shift || 1;
    my $max_retries = $svc->respawn_max_retries;
    my $factor = int(rand (2 * $retry - 1) + 1);
    return $factor * BASE_BACKOFF_DELAY;
}

=head2 up(%param)

XXX up the service (do nothing if already up)
=cut

sub up {
    my $svc = shift;
    return if $svc->is_up;
    $svc->start();
    return;
}

=head2 up(%param)

XXX down the service (do nothing if already down)
=cut

sub down {
    my $svc = shift;
    return if $svc->is_down;
    $svc->stop();
    return;
}

=head2 restart(%param)

=cut
sub restart {
    my $svc = shift;
    die "snif";
}

=head2 status_as_text

Return a text describing the service state.
It consists in tab separated list of fields:

=over 2

=item * name

=item * state

=item * pid

=item * start_time

=item * stop_time

=item * fail_reason

=item * running_cmd

=back

=cut

sub status_as_text {
    my $svc = shift;
    return join "\t", map { $svc->$_ || "" }
           qw/name state pid start_time stop_time fail_reason running_cmd/;
}

=head2 desc_as_text

Return a text describing the service and how to access it.
It consists in tab separated list of fields:

=over 2

=item * name

=item * tags

=item * desc

=back

=cut
sub desc_as_text {
    my $svc = shift;
    return join "\t", map { $svc->$_ || "" }
           qw/name tags desc/;
}

sub _set {
    my $svc = shift;
    my ($attr, $value) = @_;

    my $old = $svc->$attr;

    my $v = defined $value ? $value : "~";
    local $Data::Dumper::Indent = 0;
    local $Data::Dumper::Terse = 1;
    if (ref $v) {
        $v = Data::Dumper::Dumper($v);
    }
    if ($old) {
        my $oldv = defined $old ? $old : "~";
        $oldv = Data::Dumper::Dumper($oldv) if ref $oldv;
        $svc->{ctrl}->log->debug( "Changing $attr from '$oldv' to '$v'" );
    }
    else {
        $svc->{ctrl}->log->debug( "Setting $attr to '$v'" );
    }
    $svc->{$attr} = $value;
    return 1;
}

sub unset {
    my $svc = shift;
    my $attr = shift;
    $svc->{$attr} = undef;
    return 1;
}

sub set_cmd {
    my $value = (ref $_[1] ? _ARRAY($_[1]) : _STRING($_[1])) or return;
    shift->_set('cmd', $value);
}

sub set_cmd_from_con {
    my $svc = shift;
    my $value = shift;
    return $svc->unset('cmd') unless defined $value;
    if ($value =~ /^\[/) {
        $value = eval { JSON::Any->jsonToObj($value) };
        return if $@;
    }
    return $svc->set_cmd($value);
}

sub set_desc {
    my $value = _STRING($_[1]) or return;
    $value =~ s/[\n\r\t\0]+//g; ## desc should be one line
    shift->_set('desc', $value);
}

sub set_tags {
    my $value = _STRING($_[1]) or return;
    $value =~ s/\s+//g; ## no space in tags thanks
    shift->_set('tags', $value);
}

sub set_stopwait_secs {
    my $value = _NUMBER($_[1]) or return;
    shift->_set('stopwait_secs', $value);
}

sub set_start_secs {
    my $value = _NUMBER($_[1]) or return;
    shift->_set('start_secs', $value);
}

sub set_pipe_stdin {
    my $value = _STRING($_[1]) or return;
    shift->_set('pipe_stdin', $value);
}

sub set_ignore_stderr {
    my $value = _STRING($_[1]);
    return unless defined $value;
    shift->_set('ignore_stderr', $value);
}

sub set_ignore_stdout {
    my $value = _STRING($_[1]);
    return unless defined $value;
    shift->_set('ignore_stdout', $value);
}

sub set_respawn_on_fail {
    my $value = _STRING($_[1]);
    return unless defined $value;
    shift->_set('respawn_on_fail', $value);
}

sub set_respawn_on_stop {
    my $value = _STRING($_[1]);
    return unless defined $value;
    shift->_set('respawn_on_stop', $value);
}

sub set_respawn_max_retries {
    my $value = _POSINT($_[1]);
    return unless defined $value;
    shift->_set('respawn_max_retries', $value);
}

sub _run_cmd {
    my $svc = shift;
    my $ctrl = $svc->{ctrl};
    $ctrl->log->info( sprintf "starting %s", $svc->name );

    my %stds = (
        "<"  => "/dev/null",
        "2>" => "/dev/null",
        ">"  => "/dev/null",
    );
    $stds{"<"} = $svc->pipe_stdin if $svc->pipe_stdin;

    ## what happens when the config changes?
    ## watcher *won't* get redefined leading to configuration
    ## not being takin into account until restart of the svc.
    ## should we have a watcher reloading function? that will
    if (my $logger = $ctrl->log) {
        ## XXX verify leaks
        unless ($svc->ignore_stdout) {
            $stds{">"} = $logger->svc_watcher(out => $svc);
        }
        unless ($svc->ignore_stderr ) {
            $stds{"2>"} = $logger->svc_watcher(err => $svc);
        }
    }
    $svc->{child_cv} = AnyEvent::Util::run_cmd(
        $svc->cmd,
        close_all => 1,
        on_prepare => sub {}, ## XXX setsid etc...?
        '$$' => \$svc->{pid},
        %stds,
    );
    $svc->{child_cv}->cb( sub {
        my $es = shift()->recv;
        $svc->{child_cv} = undef;
        $svc->{pid} = undef;
        $svc->{exit_status} = $es;
        my $state;
        if (POSIX::WIFEXITED($es) && !POSIX::WEXITSTATUS($es)) {
            $svc->{ctrl}->log->info("child exited");
            $state = "stopped";
        }
        elsif (POSIX::WIFSIGNALED($es) && POSIX::WTERMSIG($es) == SIGTERM) {
            $svc->{ctrl}->log->info("child gracefully killed");
            $state = "stopped";
        }
        else {
            return $svc->deal_with_failure;
        }
        $svc->{state} = $state;
    });
    return 1;
}

sub deal_with_failure {
    my $svc = shift;

    my $es = $svc->{exit_status};
    $svc->{ctrl}->log->error("child terminated abnormally $es");

    ## If we don't respawn on fail... just fail
    if (! $svc->respawn_on_fail) {
        $svc->{state} = 'fail';
        return;
    }

    ## If the service failed while starting, enter backoff loop
    if ($svc->is_starting) {
        my $n = ++$svc->{backoff_retry} || 1;
        if ($n >= $svc->{respawn_max_retries}) {
            ## Exhausted options: bail
            $svc->{state}      = 'fatal';
            $svc->{backoff_cv} = undef;
            $svc->{start_cv}   = undef;
            return;
        }
        $svc->{state}= "backoff";
        my $backoff_delay = $svc->_exponential_backoff_delay($n);
        $svc->{backoff_retry} = $n;
        $svc->{backoff_cv} = AE::timer $backoff_delay, 0,
                                       sub { $svc->_backoff_restart };
    }
    ## Otherwise, just restart the failed service
    else {
        $svc->start;
    }

    return;
}

=head1 AUTHOR

Yann Kerherve E<lt>yannk@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<ControlFreak>

=cut

1;
