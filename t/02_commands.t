use strict;
use Find::Lib libs => [ '.', '../lib' ];
use Test::More tests => 47;
use ControlFreak;
use AnyEvent;
use AnyEvent::Handle;

use_ok 'ControlFreak::Command';
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
        ok_cb  => sub { $ok = 1; },
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
    like_error qr/void/, cmd => "";
    like_error qr/void/, cmd => undef;
    like_error qr/void/;
    like_error qr/void/, cmd => " ";
    like_error qr/void/, cmd => "\n";
    like_error qr/void/, cmd => "\t";
    like_error qr/unknown/, cmd => "unkwown";
    like_error qr/not auth/, cmd => "service";
    like_error qr/empty serv/, has_priv => 1, cmd => "service";
    like_error qr/empty serv/, has_priv => 1, cmd => "service  ";
    like_error qr/empty serv/, has_priv => 1, cmd => "service \t ";
    like_error qr/malformed.*com/, has_priv => 1, cmd => "service \t=";
    like_error qr/malformed.*com/, has_priv => 1, cmd => "service \t==";
    like_error qr/malformed.*com/, has_priv => 1, cmd => "service a =";
    like_error qr/malformed.*com/, has_priv => 1, cmd => "service && a =b";
    like_error qr/malformed.*com/, has_priv => 1, cmd => "service a=b a =b";

    like_error qr/invalid prop/, has_priv => 1, cmd => "service a a=b";
    like_error qr/invalid prop/, has_priv => 1, cmd => "service cmd a=b";
    like_error qr/invalid prop/, has_priv => 1, cmd => "service cmdcmd a=b";

    like_error qr/not auth/, has_priv => 0, cmd => "service a cmd=b";

    ## Invalid JSON
    like_error qr/invalid value/, has_priv => 1, cmd => "service a cmd= [b";
    like_error qr/invalid value/, has_priv => 1, cmd => "service a cmd= [[b";
    like_error qr/invalid value/, has_priv => 1, cmd => "service a cmd=[{b}]";
}

## valid commands
{
    process ignore_void =>1, cmd => "";
    ok !$ok && !$error, "just ignored";

    ok ! $ctrl->service('somesvc');
    process_ok(has_priv => 1, cmd => "service somesvc cmd = some command");
    ok my $svc = $ctrl->service('somesvc'), "now somesvc has been created";
    is $svc->cmd, "some command", "whitespaces trimmed";

    process_ok(has_priv => 1, cmd => "service somesvc cmd  ==  some command");
    is $svc->cmd, "=  some command", "= some command";

    process_ok(has_priv => 1, cmd => "service somesvc cmd=");
    is $svc->cmd, undef;
    process_ok(has_priv => 1, cmd => "service somesvc cmd=  ");
    is $svc->cmd, undef;
    process_ok(has_priv => 1, cmd => "service somesvc cmd= \t ");
    is $svc->cmd, undef;
    process_ok(has_priv => 1, cmd => "service somesvc cmd= \n");
    is $svc->cmd, undef;
    process_ok(has_priv => 1, cmd => "service somesvc cmd=\n");
    is $svc->cmd, undef;

    process_ok(has_priv => 1, cmd => 'service somesvc cmd="something"');
    is $svc->cmd, 'something', "DWIM double quotes";

    process_ok(has_priv => 1, cmd => "service somesvc cmd='something'");
    is $svc->cmd, 'something', "DWIM quotes";

    ## json array
    process_ok(has_priv => 1, cmd => "service somesvc cmd=[\"a\", \"b\"]");
    is_deeply $svc->cmd, ['a', 'b'];
}
