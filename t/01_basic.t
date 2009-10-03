use strict;
use Find::Lib '../lib';
use Test::More tests => 57;
use ControlFreak;
use AnyEvent;
use AnyEvent::Handle;
use Test::FindFreePort;
use Time::HiRes qw/gettimeofday tv_interval/;

use_ok 'ControlFreak::Console';

# bare, useless controller
{
    my $ctrl = ControlFreak->new();
    isa_ok $ctrl, 'ControlFreak';
    ok !$ctrl->config_file, "no config";
    ok !$ctrl->console, "no console";
    ok !$ctrl->services, "no services";
}

## console
{
    my $ctrl = ControlFreak->new();
    my $con = ControlFreak::Console->new(
        host => '127.0.0.1',
        service => 0,
        full => 1,
        ctrl => $ctrl,
    );
    is $ctrl->console, $con, "Console assigned";
    my $port_cv = AE::cv;

    my $g; $g = $con->start(prepare_cb => sub {
        my ($fh, $host, $port) = @_;
        $port_cv->send([ $host, $port ]);
        return;
    });

    $port_cv->cb( sub {
        my $conn_info = shift->recv;
        my $cv = AE::cv;
        my $clhdl; $clhdl = AnyEvent::Handle->new (
            connect => $conn_info,
            on_connect => sub { ok "1", "connected" },
            on_eof => sub {
                ok 1, "EOF called";
                $cv->send;
            },
        );
        $clhdl->push_read(sub { ok "read" });
        $cv->recv;
    });
}

## create our first service, and manipulate it
{
    my $ctrl = ControlFreak->new();
    my $svc = $ctrl->find_or_create_svc('testsvc');
    isa_ok $svc, 'ControlFreak::Service';
    is $svc->name, 'testsvc', "name is set";
    is $svc->cmd, undef, "no command";
    is $svc->start_time, undef;
    is $svc->state, 'stopped';

    ok !$svc->is_up, "not up";
    ok  $svc->is_down, "is down";
    ok !$svc->is_fail, "not fail";
    ok  $svc->is_stopped, "yes, it's stop";

    ## Cannot stop a not started service
    my $called = 0; # err_cb is called synchronously
    $svc->stop(
        err_cb => sub {  $called++; like shift, qr/already down/ },
        ok_cb  => sub { ok 0, "Oh noes!" },
    );
    is $called, 1, "Called indeed";

    ## start is doomed to fail without a declared command
    $called = 0; # err_cb is called synchronously
    $svc->start(err_cb => sub {
        ok "got an error";
        like shift, qr/command/;
        $called++;
    });
    is $called, 1, "Called indeed";
    is $svc->start_time, undef;
    is $svc->pid, undef;

    ok  $svc->is_down;
    ok !$svc->is_up;

    ## now set a real command
    $svc->set_cmd("sleep 10");
    is $svc->cmd, "sleep 10";
    ok $svc->is_stopped;
    $svc->start( ok_cb => sub {  ok 1, "started" },
                 err_cb => sub { ok 0, "oh noes" } );

    like $svc->pid, qr/^\d+$/;
    ok  my $prev_start_time = $svc->start_time, "now we have a start time";
    ok !$svc->is_running;
    ok  $svc->is_starting;
    ok !$svc->is_down;
    ok  $svc->is_up;
    ok !$svc->is_stopped;
    is  $svc->state, "starting";

    $svc->stop;
    ## XXX Race condition?
    is $svc->state, "stopping";
    ok  $svc->is_stopping;
    ok  $svc->is_up, "is up";
    ok !$svc->is_down;
    ok !$svc->is_running;
    ok !$svc->is_fail;
    ok !$svc->is_stopped;
    ok !$svc->is_starting;

    ok wait_for_down($svc);
    ok  $svc->stop_time;
    ok !$svc->start_time;
    ok !$svc->pid;

    $svc->set_cmd(q/perl -e 'die "oh noes"'/);
    $svc->start;
    ok $svc->pid, "got a pid";
    ok $svc->is_starting, "is starting (well supposedly)";
    ok $svc->start_time >= $prev_start_time, "new start time";
    ok wait_for_fail($svc, 2);
    ok $svc->is_down, "so now we are down";
    like $svc->fail_reason, qr/255/, "exit code";
    unlike $svc->fail_reason, qr/signal/, "no signal";
}

sub wait_for_down { wait_for_status('is_down', @_) }
sub wait_for_fail { wait_for_status('is_fail', @_) }

sub wait_for_status {
    my $cond = shift;
    my $svc = shift;
    my $max_wait = shift || 1;
    my $iv = 0.05;
    my $stopped = AE::cv;
    my $t0 = [gettimeofday];
    my $w; $w = AE::timer 0, $iv, sub {
        my $timeout = tv_interval($t0) > $max_wait;
        if ($svc->$cond or $timeout) {
            $stopped->send(!$timeout);
            undef $w;
        }
    };
    return $stopped->recv;
}
