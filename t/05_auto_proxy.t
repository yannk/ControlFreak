use strict;
use Find::Lib libs => '.', '../lib';
use Test::More tests => 10;
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

## test proxy interface
{
    my $s = Find::Lib->catfile('..', 'bin', 'cfk-share-mem-proxy.pl');
    my $p = Find::Lib->catfile('preload.pl');
    my $i = Find::Lib->catdir('../lib');
    my $cmd = Find::Lib->catfile('sleeper.pl');
    my $ctrl = ControlFreak->new();
    my $svc  = ControlFreak::Service->new(
        ctrl => $ctrl,
        name => 'somesvc',
        cmd  => $cmd,
        startwait_secs => .25,
    );

    my $proxy = ControlFreak::Proxy->new(
        ctrl => $ctrl,
        name => 'a',
        cmd  => "$^X -I $i $s --preload $p",
    );
    ok $proxy->auto, "proxy is auto";
    $proxy->add_service($svc);
    is scalar $proxy->services, 1, "one service";

    ok $svc->{proxy}, "proxy is still there";
    is $svc->{proxy}, $proxy, "same proxy";
    ok ! $proxy->is_running, "proxy not running yet";

    $svc->start;
    ok $svc->is_starting, "service is starting";
    wait_for (sub { $svc->is_running });
    ok $svc->is_running, "svc is running";
    ok $proxy->is_running, "proxy automatically started";
    wait_for (sub { $svc->is_running });
    $svc->stop;
    wait_for (sub { !$proxy->is_running }, 4);
    ok !$proxy->is_running, "proxy automatically stopped";

    ## Service is dying, proxy should restart each time too. getting a new PID
    #$svc->set_cmd(Find::Lib->catfile('die.pl'));
}
