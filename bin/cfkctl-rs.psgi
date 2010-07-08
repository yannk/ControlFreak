#!/usr/bin/env perl
use strict;
use warnings;

use Plack::Request;
use Plack::Response;
use Plack::Builder;
use ControlFreak::Commander;
use ControlFreak::Util;
use Router::Simple::Declare;

## move as attribute
$ControlFreak::Commander::can_color = 0;
my $address = "unix:/$ENV{HOME}/.controlfreak/sock";
my $socket = ControlFreak::Util::get_sock_from_addr($address);
my $cmd = ControlFreak::Commander->new(
    socket => $socket,
);

my $router = router {
    connect '/', { action => 'index' };
};

sub index {
    my ($req, $p) = @_;
    my $res = $req->new_response(200);

    my $data = $cmd->cmd_status;
    $res->content($data);
    $res->content_type('text/plain');
    return $res->finalize;
}

my $app = sub {
    my $env = shift;

    my $p = $router->match($env);
    unless ($p) {
        return Plack::Response->new(404)->finalize;
    }

    my $req = Plack::Request->new($env);
    my $action = delete $p->{action};
    my $method = __PACKAGE__->can($action)
        or die "Cannot do $action";
    return $method->($req, $p);
};

builder {
    ##enable 'Debug';
    enable 'Head';
    $app;
};
