use strict;
use Find::Lib libs => ['../lib', '.'];
use Test::More tests => 21;
require 'testutils.pl';
use ControlFreak;
use AnyEvent;
use AnyEvent::Handle;

shutoff_logs();

## Those timing are a bit tricky... hope it won't
## fail on some systems
{
    my $ctrl = ControlFreak->new();
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

    ## now, a service terminating abnormally will automatically respawn
    ## unless the contrary is specified (see later).

    ## if a service is starting and fail, backoff, until tried everything
    my $b = $ctrl->find_or_create_svc('b');
    ok $b->respawn_on_fail, "by default we respawn on fail";
    is $b->{backoff_retry}, undef, "no retry yet";
    $b->set_cmd('sleep .15; exit 255'); # .15 << 1 the default
    my $max = 3; ## limit the max retries so test don't take forever
    $b->set_respawn_max_retries($max);
    $b->start;
    wait_for_starting($b);
    ok $b->is_starting, 'starting' or diag $b->state;
    wait_for_backoff($b);
    ok $b->is_backoff, 'backoff state';
    ok $b->is_down, 'backoff is a down state';
    is $b->{backoff_retry}, 1, "retried once";
    wait_for(sub { $b->{backoff_retry} >= $max }, 7);
    is $b->{backoff_retry}, $max, "reached the max retry";
    ok $b->is_fatal;
    is $b->state, "fatal";

    ## if a service is running and fail, respawn by restarting it.
    my $wait = AE::cv;
    my $c = $ctrl->find_or_create_svc('c');
    $c->set_start_secs(0.001); ## very sort time
    $c->set_cmd('sleep .25; exit 255'); # .25 >> .001
    $c->start;
    my $pid = $c->pid;
    my $t1 = AE::timer 0.15, 0, sub {
        ok $c->is_running, "is running";
        is $c->pid, $pid, "still same process";
        ## give us time when it restarts;
        $c->set_cmd('sleep 300; exit 255');
    };
    my $t2 = AE::timer 0.35, 0, sub {
        isnt $c->pid, $pid, "now in a new process";
        ok $c->is_running, "but still running";
        $wait->send;
        $c->stop;
    };
    $wait->recv;

    ## if a service fail during startup but respawn_on_fail is false, then
    ## we leave it that way
    my $d = $ctrl->find_or_create_svc('d');
    $d->set_respawn_on_fail(0);
    ok !$d->respawn_on_fail, "unset";
    is $d->{backoff_retry}, undef, "no retry yet";
    $d->set_cmd('sleep .15; exit 255'); # .15 << 1 the default
    $d->start;
    wait_for_starting($d);
    ok $d->is_starting, 'starting' or diag $d->state;
    wait_for_fail($d);
    is $d->{backoff_retry}, undef, "we didn't even retry";
}
