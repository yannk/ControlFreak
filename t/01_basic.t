use strict;
use Find::Lib '../lib';
use Test::More tests => 36;
use ControlFreak;
use AnyEvent;
use AnyEvent::Handle;

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
    ## FIXME, what is that module that look for available ports?
    my $port = 3833;
    my $ctrl = ControlFreak->new();
    my $con = ControlFreak::Console->new(
        host => '127.0.0.1',
        service => $port,
        full => 1,
        ctrl => $ctrl,
    );
    is $ctrl->console, $con, "Console assigned";
    my $cv = AE::cv;
    my $g = $con->start;

    my $clhdl; $clhdl = AnyEvent::Handle->new (
        connect => [localhost => $port],
        on_connect => sub { ok "1", "connected" },
        on_eof => sub {
            ok 1, "EOF called";
            $cv->send;
        },
    );
    $clhdl->push_read(sub { ok "read" });
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

    ## start is doomed to fail without a declared command
    my $called = 0; # err_cb is called synchronously
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
    ok  $svc->start_time, "now we have a start time";
    ok !$svc->is_running;
    ok  $svc->is_starting;
    ok !$svc->is_down;
    ok  $svc->is_up;
    ok !$svc->is_stopped;
    is  $svc->state, "starting";
}
