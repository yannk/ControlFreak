use strict;
use Find::Lib libs => ['../lib', '.'];
use Test::More tests => 18;
require 'testutils.pl';

use ControlFreak;
use AnyEvent;
use AnyEvent::Handle();
use AnyEvent::Socket();

use_ok 'ControlFreak::Socket';

my $SOCKCAT = "$Find::Lib::Base/sockcat.pl";

# can't shutoff logs since it's used later for testing
shutoff_logs();

my $ctrl = ControlFreak->new();

## Create a socket object
{
    my $sock = ControlFreak::Socket->new(
        ctrl    => $ctrl,
        name    => 'testsock',
        host    => '127.0.0.1',
        service => 0,
    );
    isa_ok $sock, "ControlFreak::Socket";
    is $sock->name, 'testsock';
    ok !$sock->is_bound, "sock is not bound";
    $sock->bind;
    isnt $sock->service, 0, "wildcard replaced";
    ok $sock->is_bound;

    ## creating a socket with the same name will fail
    my $sock2 = ControlFreak::Socket->new(
        ctrl    => $ctrl,
        name    => 'testsock',
        host    => '127.0.0.2',
        service => 80,
    );
    is $sock2, undef;

    ## without controller we also return undef.
    my $sock3 = ControlFreak::Socket->new(
        name    => 'testsock2',
        host    => '127.0.0.3',
        service => 81,
    );
    is $sock3, undef, "socket undef";

    $ctrl->remove_socket($sock->name);
    $sock = undef;

    $sock = ControlFreak::Socket->new(
        ctrl    => $ctrl,
        name    => 'testsock',
        host    => '127.0.0.1',
        service => 0,
    );
    ok $sock, "socket recreation worked";
    $ctrl->remove_socket($sock->name);
}

## share the socket between two services
## Create a socket object
{
    ## create the shared socket.
    ## since s1 is set to print what it read from stdin,
    ## we will get what we pushed to the socket back in the logs
    my $sock = ControlFreak::Socket->new(
        ctrl     => $ctrl,
        name     => 'testsock',
        host     => '127.0.0.1',
        service  => 0,
    );
    ok $sock, "created socket";
    my $svc = $ctrl->find_or_create_svc("s1");
    $svc->set_cmd("$SOCKCAT s1"); # pipe stdin to stdout
    $svc->set_tie_stdin_to('testsock');
    is $svc->tie_stdin_to, 'testsock', "tie_stdin_to set";

    $sock->bind;
    $svc->start;

    ## capture every log messages from services
    my $logger = $ctrl->log->log_handle('service');
    my $test = Log::Log4perl::Appender->new(
        "Log::Log4perl::Appender::TestBuffer"
    );
    $logger->add_appender($test);

    say_socket($sock => "hello s1");

    my $test_buffer;
    wait_for(sub { $test_buffer = $test->buffer });
    like $test_buffer, qr/INFO - s1 hello s1/, "got message back";
    $test->{appender}->reset; $test_buffer = undef;
    ok $svc->is_stopped, "stopped after one request";

    ## now, with multiple children
    $svc->set_cmd("$SOCKCAT s1 3"); # pipe stdin to stdout
    $svc->start;
    my $svc2 = $ctrl->find_or_create_svc("s2");
    $svc2->set_cmd("$SOCKCAT s2 2"); # pipe stdin to stdout
    $svc2->set_tie_stdin_to('testsock');
    $svc2->start;
    say_socket($sock => "iter1");
    ok $svc->is_starting, 's1 starting';
    ok $svc2->is_starting, 's2 starting';
    for (2..6) {
        say_socket($sock => "iter$_");
    }
    wait_for(sub { my @a = split /\n/, $test->buffer; @a == 5  });
    my $buffer = $test->buffer;
    my @logs = split "\n", $buffer;
    is scalar @logs, 5, "5, the last one got lost (no children connected)";
    my %expected = (1 => 3, 2 => 2);
    for (@logs) {
        die "malformed log" unless /s(\d) iter\d/;
        $expected{$1}--;
    }
    is $expected{1}, 0, "received all s1 logs";
    is $expected{2}, 0, "received all s2 logs";
}

sub say_socket {
    my $sock = shift;
    my $what = shift;

    my $done = AE::cv;
    my $handle;
    my $g = AnyEvent::Socket::tcp_connect $sock->host, $sock->service,
        sub {
            my ($fh, $host, $port) = @_;
            $handle = new AnyEvent::Handle
                fh     => $fh;
            $handle->push_write($what);
            $handle->on_drain( sub { $handle = undef; $done->send });
        };
    $done->recv;
    return;
}

