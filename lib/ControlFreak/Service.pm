package ControlFreak::Service;
use strict;
use warnings;

use AnyEvent '5.202';
use AnyEvent::Util();
use AnyEvent::Handle();
use Carp;
use ControlFreak::Util();
use Data::Dumper();
use JSON::XS;
use Params::Util qw{ _NUMBER _STRING _IDENTIFIER _ARRAY _POSINT };
use POSIX qw{ SIGTERM SIGKILL };
use Try::Tiny;

use constant DEFAULT_STARTWAIT_SECS => 1;
use constant DEFAULT_STOPWAIT_SECS  => 2;
use constant DEFAULT_MAX_RETRIES    => 8;
use constant BASE_BACKOFF_DELAY     => 0.3;

use Object::Tiny qw{
    name
    desc
    proxy

    state
    pid
    start_time
    stop_time
    running_cmd

    cmd
    env
    cwd
    tags
    tie_stdin_to
    ignore_stderr
    ignore_stdout
    startwait_secs
    stopwait_secs
    respawn_on_fail
    respawn_on_stop
    respawn_max_retries
    no_new_session
    user
    group
    priority
};

=pod

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
        tie_stdin_to => $fcgisock,
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

    # make the service a proxied service
    $web->assign_proxy($proxy);

=head1 DESCRIPTION

This allows manipulation of a service and its state.

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
        unless defined $svc->{respawn_max_retries};

    $svc->{startwait_secs} = DEFAULT_STARTWAIT_SECS
        unless defined $svc->{startwait_secs};

    $svc->{stopwait_secs} = DEFAULT_STOPWAIT_SECS
        unless defined $svc->{stopwait_secs};

    $svc->{ctrl} = $param{ctrl}
        or croak "Service requires a controller";

    $svc->{tags} ||= {};
    $svc->{env}  ||= {};

    return $svc;
}

sub _err { ControlFreak::Util::error(@_) }

=head2 is_fail

Returns true if the state is 'failed'

=cut

sub is_fail {
    my $state = shift->state || "";
    return $state eq 'fail';
}

=head2 is_backoff

Returns true if the state is 'backoff'

=cut

sub is_backoff {
    my $state = shift->state || "";
    return $state eq 'backoff';
}

=head2 is_fatal

Returns true if the state is 'fatal'

=cut

sub is_fatal {
    my $state = shift->state || "";
    return $state eq 'fatal';
}

=head2 is_running

Returns true if the state is 'runnnig'

=cut

sub is_running {
    my $state = shift->state || "";
    return $state eq 'running';
}

=head2 is_starting

Returns true if the state is 'starting'

=cut

sub is_starting {
    my $state = shift->state || "";
    return $state eq 'starting';
}

=head2 is_stopping

Returns true if the state is 'stopping'

=cut

sub is_stopping {
    my $state = shift->state || "";
    return $state eq 'stopping';
}

=head2 is_stopped

Returns true is service is stopped

=cut

sub is_stopped {
    my $state = shift->state || "";
    return $state eq 'stopped';
}

=head2 is_up

Returns true is service is up

=cut

sub is_up {
    my $svc = shift;
    my $state = $svc->state || "";
    return 0 unless $state =~ /^(?:running|starting|stopping)$/;

    unless ($svc->{proxy}) {
        ## just in case, verify...
        return 0 unless defined $svc->{child_cv};
        return 0 unless defined $svc->pid;
    }
    return 1;
}

=head2 is_down

Returns true unless service is up

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
    return ControlFreak::Util::exit_reason( $svc->{exit_status} );
}

=head2 stop(%param)

Initiates service shutdown.

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
    my $err = $param{err_cb} ||= sub {};
    my $ok  = $param{ok_cb}  ||= sub {};

    my $svcname = $svc->name || "unnamed service";

    if ($svc->is_backoff) {
        ## stop retrying.
        $svc->{backoff_cv}    = undef;
        $svc->{start_cv}      = undef;
        $svc->{backoff_retry} = undef;
        $svc->{state}         = 'stopped';
        $svc->{wants_down}    = 1;
        $svc->{stop_time}     = time;
        return;
    }

    return $svc->_err(%param, "Service '$svcname' is already down")
        if $svc->is_down;

    return $svc->_err(%param, "Service '$svcname' lost its pid")
        unless $svc->pid;

    $svc->{ctrl}->log->info("Stopping service '$svcname'");

    ## there is a slight race condition here, since the child
    ## might have died just before we send the TERM signal, but
    ## we trust the kernel not to reallocate the pid in the meantime
    $svc->{stop_time}  = time;
    $svc->{start_time} = undef;
    $svc->{state}      = 'stopping';
    $svc->{wants_down} = 1;

    $svc->{on_stop_cb} = $param{on_stop};
    my $stopwait_secs = $svc->stopwait_secs;
    $svc->{stop_cv} =
        AE::timer $stopwait_secs, 0, sub { $svc->_check_stopping_state };

    if (my $proxy = $svc->{proxy}) {
        $proxy->stop_service(%param, service => $svc);
    }
    else {
        my $pid = $svc->pid;
        if (! $pid) {
            my $msg = "Please retry in a bit, no pid yet";
            if (! $svc->is_starting) {
                $msg = "Something weird is going on. pid missing";
            }
            return $svc->_err(%param, $msg);
        }
        else {
            ## check that we've created a session
            my $has_new_session = !$svc->no_new_session;
            if ($has_new_session) {
                if (getpgrp($pid) == getpgrp(0)) {
                    ## don't commit suicide, thank you.
                    kill SIGTERM, $pid;
                }
                else {
                    kill -(SIGTERM), getpgrp($pid);
                }
            }
            else {
                ## ok, only kill that one pid
                kill SIGTERM, $pid;
            }
        }
    }
    $ok->();
    return 1;
}

=head2 start(%param)

Initiates service startup and returns immediately.

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
    my $err = $param{err_cb} ||= sub {};
    my $ok  = $param{ok_cb}  ||= sub {};

    my $svcname = $svc->name || "unnamed service";

    return $svc->_err(%param, "Service '$svcname' is already up")
        if $svc->is_up;

    my $cmd = $svc->cmd;
    return $svc->_err(%param, "Service '$svcname' has no known command")
        unless $cmd;

    $svc->{restart_cv}    = undef;
    $svc->{start_time}    = time;
    $svc->{stop_time}     = undef;
    $svc->{wants_down}    = undef;
    $svc->{normal_exit}   = undef;
    $svc->{backoff_retry} = undef unless $svc->is_backoff;
    $svc->{state}         = 'starting';

    $svc->set_check_running_state_timer;
    if (my $proxy = $svc->{proxy}) {
        $proxy->start_service(%param, service => $svc);
    }
    else {
        $svc->_run_cmd;
    }

    $ok->();
    return 1;
}

## set a timer to verify service is up, the timer can be reset
## a second time by the proxy when it gets the pid, it depends
## which event happens first
sub set_check_running_state_timer {
    my $svc = shift;
    my $startwait_secs = $svc->startwait_secs;
    $svc->{ctrl}->log->debug("setting timer for $startwait_secs");
    $svc->{start_cv} =
        AE::timer $startwait_secs, 0, sub { $svc->_check_running_state };
    return;
}

=head2 has_stopped($reason)

Called when a third party knows that a service has stopped. It marks the
service has stopped, no matter what the current status is.

=cut

## FIXME name
sub has_stopped {
    my $svc = shift;
    my $reason = shift || "";
    return if $svc->is_down;

    my $name = $svc->name;
    $reason = "'$name' has stopped: $reason";
    $svc->{state} = 'fail';
    $svc->{stop_time} = time;
    $svc->{normal_exit} = undef;
    $svc->{child_cv} = undef;
    $svc->{ctrl}->log->info($reason);
    return 1;
}

sub _check_stopping_state {
    my $svc = shift;
    my $on_stop = $svc->{on_stop_cb};
    $svc->{stop_cv} = undef;
    $svc->{on_stop_cb} = undef;
    if ($svc->is_stopped) {
        $on_stop->($svc) if $on_stop;
        return;
    }

    my $wait = $svc->stopwait_secs;
    my $name = $svc->name;
    if ($svc->pid) {
        $svc->{ctrl}->log->warn(
            "service $name still running after $wait, killing."
        );
        $svc->kill;
    }
    else {
        $svc->{ctrl}->log->error( "service $name not stopped but, not pid?");
        $svc->{state} = 'fail';
    }
    return;
}

=head2 kill

Kills the service. This is the brutal way of getting rid of service's process
it will result in the program being uncleanly exited which will be reported
later in the status of the service. This command is used when a service
hasn't terminated after C<stopwait_secs>.

=cut

sub kill {
    my $svc = shift;
    my $pid = $svc->pid;
    unless ($pid) {
        my $name = $svc->name;
        $svc->{ctrl}->log->error( "cannot kill $name without pid" );
    }
    kill -(SIGKILL), getpgrp($pid);
}

sub _check_running_state {
    my $svc = shift;
    $svc->{start_cv} = undef;
    $svc->{ctrl}->log->debug("state is " . $svc->state);
    return unless $svc->is_starting;
    if (! $svc->pid) {
        if (my $proxy = $svc->{proxy}) {
            $svc->{ctrl}->log->warn(
                "increase startwait_secs, proxy didn't have time to start svc"
            );
            return;
        }
        $svc->{ctrl}->log->error("smth went terribly wrong");
        $svc->{state} = 'fail';
        return;
    }
    my $name = $svc->name;
    $svc->{ctrl}->log->debug("Now setting '$name' service as running");
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
    return $svc->start(@_);
}

=head2 up(%param)

XXX down the service (do nothing if already down)

=cut

sub down {
    my $svc = shift;
    my %param = @_;
    if ($svc->is_down) {
        $param{on_stop}->() if $param{on_stop};
        return;
    }
    return $svc->stop(@_);
}

=head2 restart(%param)

Restarts the service. i.e. stops it (if up), then starts it.

=cut

sub restart {
    my $svc = shift;
    my %param = @_;
    my $err = $param{err_cb} ||= sub {};
    my $ok  = $param{ok_cb}  ||= sub {};
    my $fail = 0;
    $svc->down(%param, ok_cb => $ok, err_cb => sub { $fail++ });
    return $err->() if $fail;
    my $stopwait_secs = $svc->stopwait_secs || DEFAULT_STARTWAIT_SECS;
    my $delay = $stopwait_secs / 10;
    my $tries = 0;
    $svc->{restart_cv} = AE::timer 0.15, $delay, sub {
        $tries++;
        if ($tries > 150) {
            $err->();
            return;
        }
        return if $svc->is_up;
        $svc->{restart_cv} = undef;
        return $svc->up(%param);
    };
    return;
}

=head2 proxy_as_text

A descriptive text representing service's proxy.

=cut

sub proxy_as_text {
    my $svc = shift;
    my $proxy = $svc->{proxy};
    return "" unless $proxy;
    my $name = $proxy->name || "";
    my $status = $proxy->is_running ? "" : "!";
    return "$name$status";
}

=head2 status_as_text

Returns a text describing the service state.
It consists in tab separated list of fields:

=over 2

=item * name

=item * state

=item * pid

=item * start_time

=item * stop_time

=item * proxy, prefixed with '!' if down

=item * fail_reason

=item * running_cmd

=back

=cut

sub status_as_text {
    my $svc = shift;
    return join "\t", map { $svc->$_ || "" }
           qw/name state pid start_time stop_time proxy_as_text
              fail_reason running_cmd/;
}

=head2 desc_as_text

Returns a text describing the service and how to access it.
It consists in tab separated list of fields:

=over 2

=item * name

=item * tags

=item * desc

=item * proxy

=item * cmd

=back

=cut

sub desc_as_text {
    my $svc = shift;
    return join "\t", map { $svc->$_ || "" }
        qw/name tags_as_text desc proxy_as_text cmd/;
}

=head2 assign_proxy($proxy)

=cut

sub assign_proxy {
    my $svc = shift;
    $svc->{proxy} = shift;
    return 1;
}

=head2 assign_pid($pid)

=cut

sub assign_pid {
    my $svc = shift;
    my $pid = shift;
    $svc->{pid} = $pid;
    return;
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

=head2 tags

Returns a hashref of tags

=head2 tags_as_text

Returns tag as a descriptive text.

=head2 tag_list

Returns a reference to a list of tags

=cut

sub tags_as_text {
    my $svc = shift;
    return join ", ", @{ $svc->tag_list };

}

sub tag_list {
    my $svc = shift;
    return [ keys %{ $svc->tags } ];
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
        $value = try { decode_json($value) }
        catch {
            my $error = $_;
            $svc->{ctrl}->log->error("Invalid JSON: $error");
            return;
        };
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
    my %hash_value = map { $_ => 1 } split (',', $value);
    shift->_set('tags', \%hash_value);
}

sub set_add_env {
    my $svc = shift;
    my $value = _STRING($_[0]) or return;
    my ($key, $val) = split /=/, $value, 2;
    $svc->{ctrl}->log->debug( "Setting ENV{$key} to '$val'" );
    $svc->add_env($key, $val);
}

=head2 add_env($key => $value)

Adds an environment key, value pair to the service

=cut

sub add_env {
    my $svc = shift;
    my ($key, $value) = @_;
    $svc->env->{$key} = $value;
    return 1;
}

=head2 clear_env()

Resets service environment to empty.

=cut

sub clear_env {
    my $svc = shift;
    $svc->{env} = {};
}

sub set_stopwait_secs {
    my $value = _NUMBER($_[1]) or return;
    shift->_set('stopwait_secs', $value);
}

sub set_startwait_secs {
    my $value = _NUMBER($_[1]) or return;
    shift->_set('startwait_secs', $value);
}

sub set_tie_stdin_to {
    my $value = _STRING($_[1]) or return;
    shift->_set('tie_stdin_to', $value);
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

sub set_no_new_session {
    my $value = _STRING($_[1]);
    return unless defined $value;
    shift->_set('no_new_session', $value);
}

sub _run_cmd {
    my $svc = shift;
    my $ctrl = $svc->{ctrl};
    my $svcname = $svc->name;
    $ctrl->log->info( sprintf "starting %s", $svcname );

    my %stds = (
        "<"  => "/dev/null",
        ">"  => "/dev/null",
        "2>" => "/dev/null",
    );
    if (my $sockname = $svc->tie_stdin_to) {
        my $socket = $ctrl->socket($sockname);
        if ($socket) {
            if ($socket->is_bound) {
                $ctrl->log->debug(
                    "Socket '$sockname' piped to stdin for '$svcname'"
                );
                $stds{"<"} = $socket->fh;
            }
            else {
                ## That's a bit annoying should we try to connect?
                ## XXX probably
                $ctrl->log->error(
                    "Socket '$sockname' not bound. Fatal '$svcname'"
                )
            }
        }
    }

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
        on_prepare => sub {
            $svc->prepare_child;
        },
        '$$' => \$svc->{pid},
        %stds,
    );
    $svc->{child_cv}->cb( sub {
        my $es = shift()->recv;
        $svc->acknowledge_exit($es);
    });
    return 1;
}

sub prepare_child {
    my $svc = shift;
    unless ($svc->no_new_session) {
        my $sessid = POSIX::setsid();
        $svc->{ctrl}->log->error("cannot create new session for service")
            unless $sessid;
    }
    $svc->setup_environment;
    return;
}

=head2 setup_environment

Executed in the child before exec, to take service's configured C<env> and
populate C<%ENV> with it.

=cut

sub setup_environment {
    my $svc = shift;
    my $env = $svc->env;
    return unless $env;
    return unless ref $env eq 'HASH';
    while (my ($k, $v) = each %$env) {
        $ENV{$k} = $v;
    }
    $ENV{CONTROL_FREAK_ENABLED} = 1;
    $ENV{CONTROL_FREAK_SERVICE} = $svc->name;
    return 1;
}

sub acknowledge_exit {
    my $svc = shift;
    my $es = shift;

    my $ctrl    = $svc->{ctrl};
    my $name    = $svc->name;
    my $on_stop = $svc->{on_stop_cb};

    ## reset timers, set basic new state
    $svc->{on_stop_cb}  = undef;
    $svc->{stop_cv}     = undef;
    $svc->{start_cv}    = undef;
    $svc->{child_cv}    = undef;
    $svc->{pid}         = undef;
    $svc->{exit_status} = $es;

    if (POSIX::WIFEXITED($es) && !POSIX::WEXITSTATUS($es)) {
        $ctrl->log->info("child $name exited");
        $svc->{normal_exit} = 1;
    }
    elsif (POSIX::WIFSIGNALED($es) && POSIX::WTERMSIG($es) == SIGTERM) {
        $ctrl->log->info("child $name gracefully killed");
    }
    else {
        return $svc->deal_with_failure;
    }
    $svc->{state} = 'stopped';
    $on_stop->() if $on_stop;
    $svc->optionally_respawn;
}

## What to do when process doesn't exit cleanly
sub deal_with_failure {
    my $svc = shift;

    my $es = $svc->{exit_status};
    my $r  = ControlFreak::Util::exit_reason( $es );
    $svc->{ctrl}->log->error("child terminated abnormally $es: $r");

    ## If we don't respawn on fail... just fail
    if (! $svc->respawn_on_fail) {
        $svc->{state} = 'fail';
        return;
    }

    ## If we wanted the service down. Keep it that way.
    if ($svc->{wants_down}) {
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
            return;
        }
        $svc->{state}         = "backoff";
        my $backoff_delay     = $svc->_exponential_backoff_delay($n);
        $svc->{backoff_retry} = $n;
        $svc->{backoff_cv}    = AE::timer $backoff_delay, 0,
                                          sub { $svc->_backoff_restart };
    }
    ## Otherwise, just restart the failed service
    else {
        $svc->{state} = 'fail';
        $svc->start;
    }

    return;
}

sub optionally_respawn {
    my $svc = shift;
    return unless $svc->is_stopped;
    return unless $svc->respawn_on_stop;
    return if !$svc->{normal_exit}  # abnormal exits are not our business
           or $svc->{wants_down};  # we really want it down
    $svc->start;
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
