use strict;
use Find::Lib libs => ['../lib', '.'];
use Test::More tests => 88;
use Test::Exception;
use ControlFreak;
use AnyEvent;
use AnyEvent::Handle;

require 'testutils.pl';
shutoff_logs();

use_ok 'ControlFreak::Console';

# bare, useless controller
{
    my $ctrl = ControlFreak->new();
    isa_ok $ctrl, 'ControlFreak';
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

    my $cv = AE::cv;
    my ($host, $port);
    my $g; $g = $con->start(prepare_cb => sub {
        (my $fh, $host, $port) = @_;
    });

    my $clhdl; $clhdl = AnyEvent::Handle->new (
        connect => [$host, $port],
        on_connect => sub {
            ok "1", "connected";
            $clhdl->push_write("command status\015\012");
        },
        on_eof => sub { $cv->send },
    );
    $clhdl->push_read(line => sub { ok 1, "read $_[1]"; $cv->send });
    $cv->recv;
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
    $svc->set_cmd("sleep 10;");
    is $svc->cmd, "sleep 10;";
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

    $svc->set_cmd([ $^X, '-e', 'die "oh noes"' ]);
    $svc->set_respawn_on_fail(0);
    $svc->start;
    ok $svc->pid, "got a pid";
    ok $svc->is_starting, "is starting (well supposedly)";
    ok $svc->start_time >= $prev_start_time, "new start time";
    ok wait_for_fail($svc, 2);
    ok $svc->is_down, "so now we are down";
    like $svc->fail_reason, qr/255/, "exit code";
    unlike $svc->fail_reason, qr/signal/, "no signal";

    $svc->set_cmd([$^X, '-e', 'kill 9, $$']);
    $svc->set_respawn_on_fail(0);
    $svc->start;
    ok wait_for_fail($svc, 2);
    unlike $svc->fail_reason, qr/Exited/, "no exit code";
    like $svc->fail_reason, qr/signal 9/, "killed";

    ## let's kill the process abruptly
    $svc->set_cmd([$^X, '-e', 'sleep 100']);
    $svc->set_respawn_on_fail(0);
    $svc->start;
    ok wait_for_starting($svc);
    ok $svc->is_starting, "now starting, let's proceed with the killings";
    kill 9, $svc->pid if $svc->pid;
    ok wait_for_fail($svc);
    ok $svc->is_down, "got killed";
    ok $svc->is_fail, "fail";
    unlike $svc->fail_reason, qr/Exited with error/, "no exit code";
    like $svc->fail_reason, qr/signal 9/, "killed";

    ## now kill it properly
    $svc->start;
    ok wait_for_starting($svc);
    ok $svc->is_starting, "now starting, let's proceed with the killings";
    kill 15, $svc->pid if $svc->pid;
    ok wait_for_down($svc);
    ok $svc->is_down, "got killed";
    ok !$svc->is_fail, "not fail";
    ok $svc->is_stopped, "is stopped";
    ok !$svc->fail_reason, "no fail reason, since we succeeded";
}

## Cannot create a service with the name '-', it's special
{
    my $ctrl = ControlFreak->new();
    my $svc = $ctrl->find_or_create_svc('-');
    is $svc, undef, "forbidden";
    $svc = ControlFreak::Service->new( name => '-' );
    is $svc, undef, "forbidden";
}

## test for the problem of sh -c being unstoppable
{
    my $ctrl = ControlFreak->new();
    my $svc = $ctrl->find_or_create_svc('testsvc');
    $svc->set_stopwait_secs(.10);
    $svc->set_cmd('sleep 10; sleep 10');
    $svc->start;
    ok wait_for_starting($svc);
    ok $svc->is_starting, "now starting";
    $svc->stop;
    ok wait_for_down($svc) or diag $svc->state;
    ok $svc->is_down, "got stopped";
}

## environment
{
    my $ctrl = ControlFreak->new();
    my $svc = $ctrl->find_or_create_svc('s');
    $svc->set_cmd(qq($^X -e 'warn \$\$; die "bye" if \$ENV{die}; sleep 100;'));
#    $svc->set_cmd(['perl', '-e', 'die "bye" if $ENV{die}; sleep 100;']);
    $svc->add_env( foo => "bar" );
    $svc->set_startwait_secs(0.10);
    $svc->set_stopwait_secs(0.10);
    $svc->start;
    ok wait_for_running($svc), "waited for running" or diag $svc->state;
    ok $svc->is_running, "is running" or diag $svc->state;
    $svc->stop;
    ok wait_for_stopped($svc), "wait for stopped" or diag $svc->state;
    $svc->add_env( die => "die" );
    $svc->start;
    ok wait_for_backoff($svc), "waited for backoff" or diag $svc->state;
    ok $svc->is_backoff, "backoff";
    $svc->clear_env;
    $svc->stop;
    ok wait_for_stopped($svc), "wait for stopped" or diag $svc->state;
    $svc->start;
    ok wait_for_running($svc), "waited for running" or diag $svc->state;
    $svc->stop;
    ok wait_for_stopped($svc), "wait for stopped" or diag $svc->state;
    $svc->set_cmd(qq($^X -e 'die "bye" if \$ENV{CONTROL_FREAK_ENABLED}; sleep 100;'));
    $svc->start;
    ok wait_for_backoff($svc), "waited for backoff" or diag $svc->state;
    ok $svc->is_backoff, "backoff, CONTROL_FREAK_ENABLED==1";
}
