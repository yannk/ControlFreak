use strict;
use Find::Lib '../lib';
use Test::More tests => 9;
use ControlFreak;
use AnyEvent;
use AnyEvent::Handle;

use_ok 'ControlFreak::Console';

# bare, useless controller
{ 
    my $cntl = ControlFreak->new();
    isa_ok $cntl, 'ControlFreak';
    ok !$cntl->config_file, "no config";
    ok !$cntl->console, "no console";
    ok !$cntl->services, "no services";
}

## console
{
    my $port = 3833;
    my $cntl = ControlFreak->new();
    my $con = ControlFreak::Console->new(
        host => '127.0.0.1',
        service => $port,
        full => 1,
        cntl => $cntl,
    );
    is $cntl->console, $con, "Console assigned";
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

