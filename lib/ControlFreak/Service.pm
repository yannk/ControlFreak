package ControlFreak::Service;
use strict;
use warnings;

use Log::Log4perl qw/:easy/;
Log::Log4perl->easy_init($DEBUG);
use AnyEvent '5.202';
use AnyEvent::Util();
use AnyEvent::Handle();
use Carp;

## stdin option name sucks?
use Object::Tiny qw{
    name
    desc

    state
    pid
    start_time
    stop_time

    cmd
    running_cmd
    env
    cwd
    stdin
    tags
    ignore_stderr
    ignore_stdout
    start_secs
    stopwait_secs
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
        stdin => $fcgisock,
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
    $svc->{ctrl} = $param{ctrl}
        or croak "Service requires a controller";
    return $svc;
}

=head2 is_fail

return true if the state is 'failed'

=cut

sub is_fail {
    my $state = shift->state || "";
    return $state eq 'failed';
}

sub is_running {
    my $state = shift->state || "";
    return $state eq 'running';
}

sub is_starting {
    my $state = shift->state || "";
    return $state eq 'starting';
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
    return 0 unless $state eq 'running' or $state eq 'starting';

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

Returns the reason of the failure, or undef.

=cut

sub fail_reason {
    my $svc = shift;
    return unless $svc->is_fail;
    return $svc->{fail_reason} || "unknown reason";
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
    if ($svc->pid) {
        $err->("Service '$svcname' lost its pid");
        return;
    }
    ## there is a slight race condition here, since the child
    ## might have died just before we send the TERM signal, but
    ## we trust the kernel not to reallocate the pid in the meantime
    kill 'TERM', $svc->pid;
    $ok->();
    $svc->{stop_time} = time;
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
    $svc->{state} = 'starting';
    $svc->_run_cmd;
    my $start_secs = 10; ## XXX
    $svc->{start_cv} = AnyEvent->timer(
        after => $start_secs,
        cb    => sub { $svc->_check_running_state },
    );

    $ok->();
    return 1;
}

sub _check_running_state {
    my $svc = shift;
    my $state = $svc->state;
    return unless $state && $state eq 'starting';
    DEBUG "Now setting the service as running";
    $svc->{state} = 'running';
}

sub up {
    my $svc = shift;
    return if $svc->is_up;
    $svc->start();
    return;
}

sub set_cmd {
    my $svc = shift;
    my $cmd = shift;
    my $old = $svc->cmd;
    if ($old) {
        INFO "Changing command from '$old' to '$cmd'";
    }
    else {
        INFO "Setting command to '$cmd'";
    }
    $svc->{cmd} = $cmd;
}

sub _run_cmd {
    my $svc = shift;
    my $ctrl = $svc->{ctrl};
    INFO sprintf "starting %s", $svc->name;

    my %stds = (
        "<"  => "/dev/null",
        "2>" => "/dev/null",
        ">"  => "/dev/null",
    );
    $stds{"<"} = $svc->stdin if $svc->stdin;

    unless ($svc->ignore_stderr) {
        my ($r, $w) = AnyEvent::Util::portable_pipe;
        croak "couldn't create a pipe" unless $r;
        $svc->{stderr} = $r;
        $stds{"2>"}    = $w;

        ## FIXME: install a std $ctrl->logger watcher
        $svc->{stderr_cv} = AE::io $r, 0, sub {
            my $input = <$r>;
            return unless defined $input;
            chomp $input;
            WARN "XXX $input";
        };
    }
    ## FIXME: ignore_stdout

    $svc->{child_cv} = AnyEvent::Util::run_cmd(
        $svc->cmd,
        close_all => 1,
        on_prepare => sub {}, ## XXX setsid etc...?
        '$$' => \$svc->{pid},
        %stds,
    );
    $svc->{child_cv}->cb( sub {
        my $status = shift()->recv;
        my $state;
        if ($status) {
            ERROR "child terminated abnormally";
            $state = "fail";
        }
        else {
            INFO "child exited";
            $state = "done";
        }
        $svc->{state} = $state;
        $svc->{stderr_cv} = undef;
        $svc->{stderr} = undef;
    });
    return 1;
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
