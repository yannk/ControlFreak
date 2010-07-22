use strict;
use Find::Lib libs => '.', '../lib';
use Test::More tests => 31;
use ControlFreak;
use AnyEvent;
use AnyEvent::Handle;

use_ok 'ControlFreak::Proxy';
require 'testutils.pl';
shutoff_logs();

my $ctrl = ControlFreak->new();
my $error;
my $ok;

### Helpers
sub process {
    $error = undef;
    $ok = undef;
    ControlFreak::Command->process(
        ctrl   => $ctrl,
        err_cb => sub { $error = shift },
        ok_cb  => sub { $ok    =     1 },
        @_
    );
    return;
};

sub like_error {
    my $re = shift;
    process(@_);
    !$error ? ok 0, "no error" : like $error, $re, "error in process";
}

sub process_ok {
    process(@_);
    my %p = @_;
    ok $ok, $p{cmd};
}

## Test some errors
{
    like_error qr/malformed proxy/, has_priv => 1, cmd => "proxy proxy";
    like_error qr/malformed prox/, has_priv => 1, cmd => "proxy service=s";
    like_error qr/malformed ser/, has_priv => 1, cmd => "proxy a service cmd=s";
    like_error qr/auth/, has_priv => 0, cmd => "proxy a service svc cmd=s";
}

## test proxy interface
{
    my $ctrl2 = ControlFreak->new();
    my $svc   = ControlFreak::Service->new(
        ctrl => $ctrl2,
        name => 'somesvc',
        cmd => 'sleep 99',
    );
    my $proxy = ControlFreak::Proxy->new(
        ctrl => $ctrl2,
        name => 'a',
        auto => 0,
    );
    ok ! $proxy->auto, "no-auto proxy";
    is $proxy->{cmd}, undef, "no command to our proxy yet";
    $proxy->add_service($svc);
    is scalar $proxy->services, 1, "one service";
    is $svc->cmd, 'sleep 99';
    ok $svc->{proxy}, "and a proxy assigned";

    ok !$proxy->is_running;
    ok !$proxy->pid;
    $proxy->run;
    ok ! $proxy->is_running, "proxy is not running, it has no command";
    $proxy->set_cmd('sleep 100');
    is $proxy->cmd, 'sleep 100', "no proxy has a (dumb) command";
    ok !$proxy->is_running, "not running";
    $proxy->run;
    ok $proxy->is_running;
    ok $proxy->pid;

    kill 'TERM', $proxy->pid if $proxy->pid;
    wait_for (sub { !$proxy->is_running });
    ok !$proxy->is_running, "proxy got killed";
    is $proxy->pid, undef, "and pid cleared";

    ## rerun the proxy
    $proxy->run;
    $svc->start;
    ok $svc->is_starting, "service is starting";
    ok $proxy->is_running, "proxy is running";
    $proxy->shutdown;
    wait_for (sub { $svc->is_down });
    ok $svc->is_fail or diag $svc->state;

    ## backoff bug
    my $s = Find::Lib->catfile('..', 'bin', 'cfk-share-mem-proxy.pl');
    my $p = Find::Lib->catfile('preload.pl');
    my $i = Find::Lib->catdir('../lib');
    $proxy->set_cmd("$^X -I $i $s --preload $p");
    $proxy->run;
    ok $svc->{proxy}, "proxy is still there";
    is $svc->{proxy}, $proxy, "same proxy";
    ok $proxy->is_running, "proxy restarted";
    $svc->set_cmd(Find::Lib->catfile('die.pl'));
    $svc->start;
    ok wait_for_starting($svc), "starting" or diag $svc->state;
    ok wait_for_backoff($svc), "backoff" or diag $svc->state;
    $svc->set_respawn_max_retries(3);
    ok wait_for_fatal($svc, 4), "fatal" or diag $svc->state;
    $proxy->shutdown;
}

## valid commands
{
    process_ok(has_priv => 1, cmd => "proxy a service somesvc cmd=sleep 99");
    ok my $proxy = $ctrl->proxy('a'), "proxy declared";
    ok my $svc = $ctrl->service('somesvc'), "now svc a has been created";
}
