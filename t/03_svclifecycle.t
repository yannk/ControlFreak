use strict;
use Find::Lib libs => ['../lib', '.'];
use Test::More tests => 51;
require 'testutils.pl';
use ControlFreak;
use AnyEvent;
use AnyEvent::Handle;

shutoff_logs();

my $ctrl = ControlFreak->new();

## Those timing are a bit tricky... hope it won't
## fail on some systems
{
    my $a = $ctrl->find_or_create_svc('a');
    $a->set_cmd('sleep .15');

    ## sanity checks
    ok !$a->is_up, "not up";
    ok  $a->is_down, "is down";

    $a->start;
    wait_for_starting($a);
    ok $a->is_starting, "starting";
    wait_for_stopped($a);
    ok $a->is_stopped, $a->state;
}

## now, a service terminating abnormally will automatically respawn
## unless the contrary is specified (see later).

## if a service is starting and fail, backoff, until tried everything
{
    my $b = $ctrl->find_or_create_svc('b');
    ok $b->respawn_on_fail, "by default we respawn on fail";
    is $b->{backoff_retry}, undef, "no retry yet";
    $b->set_cmd('sh -c "sleep .15; exit 255"'); # .15 << 1 the default
    my $max = 3; ## limit the max retries so test don't take forever
    $b->set_respawn_max_retries($max);
    $b->start;
    wait_for_starting($b);
    ok $b->is_starting, 'starting' or diag $b->state;
    wait_for_backoff($b);
    ok $b->is_backoff, 'backoff state';
    ok $b->is_down, 'backoff is a down state';
    is $b->{backoff_retry}, 1, "retried once";
    ok wait_for_starting($b), "starting again" or diag $b->state;
    ok wait_for_backoff($b), "backoff again" or diag $b->state;
    wait_for(sub { $b->{backoff_retry} >= $max }, 7);
    is $b->{backoff_retry}, $max, "reached the max retry";
    ok $b->is_fatal;
    is $b->state, "fatal";

    ## do that again
    $b->start;
    wait_for_backoff($b);
    ok $b->is_backoff, 'backoff state' or diag $b->state;
    ok $b->{backoff_retry} < $max, "backoff counter reinitialized";
    $b->stop;
    ok $b->is_stopped, "interrupted the automatic retry";
}

## if a service is running and fail, respawn by restarting it.
{
    my $wait = AE::cv;
    my $c = $ctrl->find_or_create_svc('c');
    $c->set_startwait_secs(0.001); ## very sort time
    $c->set_cmd('sh -c "sleep .25; exit 255"'); # .25 >> .001
    $c->start;
    my $pid = $c->pid;
    my $t1 = AE::timer 0.15, 0, sub {
        ok $c->is_running, "is running";
        is $c->pid, $pid, "still same process";
        ## give us time when it restarts;
        $c->set_cmd('sh -c "sleep 300; exit 255"');
    };
    my $t2 = AE::timer 0.35, 0, sub {
        isnt $c->pid, $pid, "now in a new process";
        ok $c->is_running, "but still running";
        $wait->send;
        $c->stop;
    };
    $wait->recv;
}

## if a service fail during startup but respawn_on_fail is false, then
## we leave it that way
{
    my $d = $ctrl->find_or_create_svc('d');
    $d->set_respawn_on_fail(0);
    ok !$d->respawn_on_fail, "unset";
    is $d->{backoff_retry}, undef, "no retry yet";
    $d->set_cmd('sh -c "sleep .15; exit 255"'); # .15 << 1 the default
    $d->start;
    wait_for_starting($d);
    ok $d->is_starting, 'starting' or diag $d->state;
    wait_for_fail($d);
    is $d->{backoff_retry}, undef, "we didn't even retry";
}

## respawn_on_stop, optionally restart a service that goes down
## naturally (i.e. when ControlFreak didn't initiate a stop)
{
    my $e = $ctrl->find_or_create_svc('e');
    $e->set_respawn_on_stop(1);
    $e->set_cmd('sh -c "sleep .20; exit 0"'); ## normal exit
    $e->set_startwait_secs(0.10);
    $e->start;
    wait_for_starting($e);
    ok $e->is_starting, "now starting";
    wait_for_running($e);
    ok $e->is_running, "now running";
    wait_for_starting($e);
    ok $e->is_starting, "now running again, since we stopped and restarted"
        or diag $e->state;
    $e->stop;
}

## respawn_on_stop, optionnally restart a service that goes down
## naturally (i.e. when ControlFreak didn't initiate a stop)
{
    my $f = $ctrl->find_or_create_svc('f');
    $f->set_respawn_on_stop(1);
    $f->set_cmd([$^X, '-e', 'sleep 20; exit 0', ]);
    $f->set_startwait_secs(0.10);
    ok $f->is_stopped, "initially stopped";
    $f->start;
    wait_for_running($f);
    ok $f->is_running, "now running" or diag $f->state;
    $f->stop;
    wait_for_stopped($f, 2);
    ok $f->is_stopped, "really stopped"
        or diag $f->state;
}

## same thing using the shell
{
    my $g = $ctrl->find_or_create_svc('g');
    $g->set_respawn_on_stop(1);
    $g->set_cmd('sleep 20');
    $g->set_startwait_secs(0.10);
    ok $g->is_stopped, "initially stopped";
    $g->start;
    wait_for_running($g);
    ok $g->is_running, "now running" or diag $g->state;
    $g->stop;
    wait_for_stopped($g, 2);
    ok $g->is_stopped, "really stopped"
        or diag $g->state;
}

## forcibly kill a service after stopwait_secs
{
    my $h = $ctrl->find_or_create_svc('h');
    $h->set_respawn_on_stop(1);
    $h->set_cmd([$^X, '-e', '$SIG{TERM}="IGNORE"; sleep 100']);
    $h->set_startwait_secs(0.10);
    $h->set_stopwait_secs(0.3);
    $h->start;
    wait_for_running($h);
    ok $h->is_running, "now running" or diag $h->state;
    $h->stop;
    ok wait_for_stopping($h), "stopping";
    ok ! wait_for_stopped($h, .15), "still stopping! will need to kill it";
    ok wait_for_fail($h), "finally killed with SIGKILL" or diag $h->state;
}

## restart command
{
    my $i = $ctrl->find_or_create_svc('i');
    $i->set_cmd(q|sleep 100|);
    $i->set_startwait_secs(0.10);
    $i->set_stopwait_secs(0.10);
    $i->restart(
        ok_cb => sub { ok 0, "oops, should have failed" },
        err_cb => sub { ok 1, "failed as expected" },
    );
    ok $i->is_stopped, "stopped";
    $i->start;
    ok wait_for_running($i), "now running";
    $i->restart(
        ok_cb => sub { ok 1, "ok restarted" },
        err_cb => sub { ok 0, "failed where it should have succeeded" },
    );
    ok wait_for_starting($i), "restarted" or diag $i->state;
}

## stop with a callback
{
    my $pi = $ctrl->find_or_create_svc('pi');
    $pi->set_cmd(q|sleep 100|);
    $pi->set_startwait_secs(0.10);
    $pi->set_stopwait_secs(0.20);
    $pi->start;
    ok wait_for_running($pi), "now running";
    ok $pi->is_running, "π is running";
    my $run = 0;
    $pi->stop(
        on_stop => sub {
            $run = 1;
            ok $pi->is_stopped, "now stopped";
        },
    );
    ok !$run, "not yet run";
    ok $pi->is_stopping, "now is stopping";
    ok wait_for_stopped($pi), "now stopped";
    ok $run, "callback on_stop() has run";

}
