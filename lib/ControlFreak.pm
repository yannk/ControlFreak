package ControlFreak;

use strict;
use 5.008_001;
our $VERSION = '1.0.0'; ## http://semver.org

use Object::Tiny qw{
    log
    console
    home
};

use Carp;
use ControlFreak::Command;
use ControlFreak::Logger;
use ControlFreak::Service;
use ControlFreak::Proxy;
use File::Spec();
use Params::Util qw{ _ARRAY _CODE };

our $CRLF = "\015\012";

=encoding utf8

=head1 NAME

ControlFreak - a process supervisor

=head1 SYNOPSIS

    ## WARNING
    ## see L<cfkd> and L<cfkctl> manpages for how to run ControlFreak from
    ## the shell. This is the programatic interface used by these scripts.

    $ctrl = ControlFreak->new(
        log_config_file => $log_config_file,
    );
    $ctrl->run; # enter the event loop, returns only for exiting

    ## elsewhere in the eventloop
    $ctrl->add_socket($sock);
    $sock = $ctrl->socket($sockname);

    $svc = $ctrl->find_or_create($svcname);
    $ctrl->add_service($svc);
    $svc = $ctrl->service($svcname);

    @svcs = $ctrl->service_by_tag($tag);
    @svcs = $ctrl->services;

    $ctrl->destroy($svcname);

    $ctrl->set_console($con);
    $con = $ctrl->console;
    $log = $ctrl->log;

=head1 DESCRIPTION

This is the programmer documentation. Look into L<ControlFreak/Intro.pod>
for user documentation.

=head1 METHODS

=head2 new(%param)

=over 4

=item * config

The absolute path to a initial config file.

=back

=cut

sub new {
    my $class = shift;
    my %param = @_;
    my $ctrl = $class->SUPER::new(%param);

    my $base = $ctrl->{base} = $param{base};

    $ctrl->{servicemap} = {};
    $ctrl->{socketmap}  = {};
    $ctrl->{proxymap}   = {};

    my $log_config_file;
    my $home = $param{home};
    $log_config_file = File::Spec->rel2abs($param{log_config_file}, $home)
        if defined $param{log_config_file} && $home;

    $ctrl->{log} = ControlFreak::Logger->new(
        config_file => $log_config_file,
    );

    return $ctrl;
}

=head2 services

Returns a list of L<ControlFreak::Service> instances known to this
controller.

=cut

sub services {
    my $ctrl = shift;
    return values %{ $ctrl->{servicemap} };
}

=head2 sockets

Returns a list of L<ControlFreak::Socket> instances known to this
controller.

=cut

sub sockets {
    my $ctrl = shift;
    return values %{ $ctrl->{socketmap} };
}

=head2 service($name)

Returns the service of name C<$name> or nothing.

=cut

sub service {
    my $ctrl = shift;
    my ($svcname) = shift or return;
    return $ctrl->{servicemap}{$svcname};
}

=head2 proxy($name)

Returns the proxy of name C<$name> or nothing.

=cut

sub proxy {
    my $ctrl = shift;
    my ($proxyname) = shift or return;
    return $ctrl->{proxymap}{$proxyname};
}

=head2 set_console

Takes a L<ControlFreak::Console> instance in parameter and sets it
as the console.

=cut

sub set_console {
    my $ctrl = shift;
    my $con = shift;

    $ctrl->{console} = $con;
    return;
}

=head2 socket($name)

Returns the L<ControlFreak::Socket> object of name C<$name> or returns
undef.

=cut

sub socket {
    my $ctrl = shift;
    my $name = shift || "";
    return $ctrl->{socketmap}->{$name};
}

=head2 add_socket($socket)

Adds the C<$socket> L<ControlFreak::Socket> object passed in parameters
to the list of socket this controller knows about.

If a socket by that name already exists, it returns undef, otherwise
it returns a true value;

=cut

sub add_socket {
    my $ctrl = shift;
    my $socket = shift;

    my $name = $socket->name || "";
    return if $ctrl->{socketmap}->{$name};
    $ctrl->{socketmap}->{$name} = $socket;
    return 1;
}

=head2 remove_socket($socket_name)

Removes the L<ControlFreak::Socket> object by the name of C<$socket_name>
from the list of sockets this controller knows about.

Returns true if effectively removed.

=cut

sub remove_socket {
    my $ctrl = shift;
    my $socket_name = shift;
    return delete $ctrl->{socketmap}->{$socket_name};
}

=head2 add_proxy($proxy)

Adds the C<$proxy> L<ControlFreak::Proxy> object passed in parameters
to the list of proxies this controller knows about.

If a proxy by that name already exists, it returns undef, otherwise
it returns a true value;

=cut

sub add_proxy {
    my $ctrl = shift;
    my $proxy = shift;

    my $name = $proxy->name || "";
    return if $ctrl->{proxymap}->{$name};
    $ctrl->{proxymap}->{$name} = $proxy;
    return 1;
}

=head2 remove_proxy($proxy_name)

Removes the L<ControlFreak::Proxy> object by the name of C<$proxy_name>
from the list of proxies this controller knows about.

Returns true if effectively removed.

=cut

sub remove_proxy {
    my $ctrl = shift;
    my $proxy_name = shift;
    return delete $ctrl->{proxymap}->{$proxy_name};
}

=head2 proxies

Returns a list of proxy objects.

=cut

sub proxies {
    my $ctrl = shift;
    return values %{ $ctrl->{proxymap} };
}

=head2 find_or_create_svc($name)

Given a service name in parameter (a string), searches for an existing
defined service with that name, if not found, then a new service is
declared and returned.

=cut

sub find_or_create_svc {
    my $ctrl = shift;
    my $svcname = shift;
    my $svc = $ctrl->{servicemap}{$svcname};
    return $svc if $svc;

    $svc = ControlFreak::Service->new(
        name  => $svcname,
        state => 'stopped',
        ctrl  => $ctrl,
    );
    return unless $svc;

    return $ctrl->{servicemap}{$svcname} = $svc;
}

=head2 find_or_create_sock($name)

Given a socket name in parameter (a string), searches for an existing
defined socket with that name, if not found, then a new socket is
declared and returned.

=cut

sub find_or_create_sock {
    my $ctrl = shift;
    my $sockname = shift;
    my $sock = $ctrl->{socketmap}{$sockname};
    return $sock if $sock;

    $sock = ControlFreak::Socket->new(
        name  => $sockname,
        ctrl  => $ctrl,
    );
    return unless $sock;

    return $ctrl->{socketmap}{$sockname} = $sock;
}

=head2 find_or_create_proxy($name)

Given a proxy name in parameter (a string), searches for an existing
defined proxy with that name, if not found, then a new proxy is
declared and returned.

=cut

sub find_or_create_proxy {
    my $ctrl = shift;
    my $proxyname = shift;
    my $proxy = $ctrl->{proxymap}{$proxyname};
    return $proxy if $proxy;

    $proxy = ControlFreak::Proxy->new(
        name  => $proxyname,
        ctrl  => $ctrl,
    );
    return unless $proxy;

    return $ctrl->{proxymap}{$proxyname} = $proxy;
}

=head2 logger

Returns the logger attached to the controller.

=cut

=head2 services_by_tag($tag)

Given a tag in parameter, returns a list of matching service objects.

=cut

sub services_by_tag {
    my $ctrl = shift;
    my $tag = shift;
    return grep { $_->tags->{$tag} } $ctrl->services;
}

=head2 services_from_args(%param)

Given a list of arguments (typically from the console commands)
returns a list of L<ControlFreak::Service> instances. 

=over 4

=item * args

The list of arguments to analyze.

=item * err

A callback called with the parsing errors of the arguments.

=back

=cut

sub services_from_args {
    my $ctrl = shift;
    my %param = @_;

    my $err  = _CODE($param{err_cb}) || sub {};
    my $args = _ARRAY($param{args})
        or return ();

    my $selector = shift @$args;
    if ($selector eq 'service') {
        unless (scalar @$args == 1) {
            $err->('service selector takes exactly 1 argument: name');
            return ();
        }
        my $name = shift @$args;
        my $svc = $ctrl->service($name);
        return $svc ? ($svc) : ();
    }
    elsif ($selector eq 'tag') {
        return $ctrl->services_by_tag(shift @$args);
    }
    elsif ($selector eq 'all') {
        return $ctrl->services;
    }
    else {
        $err->("unknown selector '$selector'");
    }
    return ();
}


=head2 command_*

All accessible commands to the config and the console.

=cut

sub command_start   { _command_ctrl('start',   @_ ) }
sub command_stop    { _command_ctrl('stop',    @_ ) }
sub command_restart { _command_ctrl('restart', @_ ) }
sub command_down    { _command_ctrl('down',    @_ ) }
sub command_up      { _command_ctrl('up',      @_ ) }

sub _command_ctrl {
    my $meth = shift;
    my $ctrl = shift;
    my %param = @_;

    my $err  = _CODE($param{err_cb}) || sub {};
    my $ok   = _CODE($param{ok_cb})  || sub {};
    my @svcs = $ctrl->services_from_args(
        %param, err_cb => $err, ok_cb => $ok,
    );
    if (! @svcs) {
        return $err->("Couldn't find a valid service. bailing.");
    }
    my $n = 0;
    for (@svcs) {
        $_->$meth(err_cb => $err, ok_cb => sub { $n++ });
    }
    $ok->("done $n");
    return;
}

## for now, at least this is separated.
## but could we imagine a command start all running proxies as well?
sub command_proxyup {
    my $ctrl = shift;
    my %param = @_;

    my $err  = _CODE($param{err_cb}) || sub {};
    my $ok   = _CODE($param{ok_cb})  || sub {};

    my $proxyname = $param{args}[0];

    my $proxy = $ctrl->proxy($proxyname || "");
    if (! $proxy) {
        return $err->("Couldn't find a valid proxy. bailing.");
    }
    $proxy->run;
    $ok->();
    return;
}

sub command_proxydown {
    my $ctrl = shift;
    my %param = @_;

    my $err  = _CODE($param{err_cb}) || sub {};
    my $ok   = _CODE($param{ok_cb})  || sub {};

    my $proxyname = $param{args}[0];

    my $proxy = $ctrl->proxy($proxyname || "");
    if (! $proxy) {
        return $err->("Couldn't find a valid proxy. bailing.");
    }
    $proxy->shutdown;
    $ok->();
    return;
}

sub command_list {
    my $ctrl = shift;
    my %param = @_;
    my $ok = _CODE($param{ok_cb}) || sub {};
    my @out = map { $_->name } $ctrl->services;
    $ok->(join "\n", @out);
}

sub command_desc {
    my $ctrl = shift;
    my %param = @_;

    my $ok = _CODE($param{ok_cb}) || sub {};

    my $args = $param{args} || [ 'all' ];
    $args = ['all'] unless @$args;

    my @svcs = $ctrl->services_from_args(
        %param, ok_cb => $ok,
    );
    my @out = map { $_->desc_as_text } @svcs;
    $ok->(join "\n", @out);
}

sub command_version {
    my $ctrl = shift;
    my %param = @_;
    my $ok = _CODE($param{ok_cb}) || sub {};
    $ok->($VERSION);
}

sub command_status {
    my $ctrl = shift;
    my %param = @_;

    my $ok   = _CODE($param{ok_cb}) || sub {};

    my $args = $param{args} || [ 'all' ];
    $args = ['all'] unless @$args;
    my @svcs = $ctrl->services_from_args(%param, args => $args);

    my @out;
    for (@svcs) {
        push @out, $_->status_as_text;
    }
    $ok->(join "\n", @out);
}

sub command_pids {
    my $ctrl = shift;
    my %param = @_;

    my $ok      = _CODE($param{ok_cb}) || sub {};

    my $args = $param{args} || [ 'all' ];
    $args = ['all'] unless @$args;
    my @svcs = $ctrl->services_from_args(%param, args => $args);
    my %seen;
    my @out;
    for (@svcs) {
        my $svcname = $_->name;
        next if $seen{$svcname}++;
        my @pids = ($_->pid);
        if (my $proxy = $_->proxy) {
            my $ppid = $proxy->pid;
            unshift @pids, $ppid if $ppid;
        }
        push @out, "$svcname: " . join (", ", @pids);
    }
    $ok->(join "\n", @out);
}

sub command_proxystatus {
    my $ctrl = shift;
    my %param = @_;

    my $ok      = _CODE($param{ok_cb}) || sub {};
    my @proxies = $ctrl->proxies;
    my @out;
    for my $p ($ctrl->proxies) {
        push @out, $p->status_as_text;
    }
    $ok->(join "\n", @out);
}

sub command_bind {
    my $ctrl = shift;
    my %param = @_;
    my $args = $param{args} || [];
    my $err = _CODE($param{err_cb}) || sub {};
    my $ok  = _CODE($param{ok_cb})  || sub {};
    my $sockname = shift @$args || "";
    my $sock = $ctrl->socket($sockname);
    unless ($sock) {
        return $err->("unknown socket '$sockname'");
    }
    $sock->bind();
    $ok->();
    return;
}

sub command_shutdown {
    ## I'm tired of killing my procs.
    ## might not stay in the future
    my $ctrl = shift;
    $ctrl->shutdown;
    $ctrl->{exit_cv} = AE::timer 1, 0, sub { exit };
}

sub command_destroy {
    my $ctrl = shift;
    my %param = @_;

    my $err = _CODE($param{err_cb}) || sub {};
    my $ok  = _CODE($param{ok_cb})  || sub {};

    my @svcs = $ctrl->services_from_args(
        %param, err_cb => $err, ok_cb => $ok,
    );
    my %errors;
    for my $svc (@svcs) {
        my $svcname = $svc->name;
        $svc->down(
            on_stop => sub { $ctrl->destroy($svc) },
            err_cb => sub {
                $errors{$svcname}++;
            },
        );
    }
    if (keys %errors) {
        my $list = join ", ", keys %errors;
        $err->("Coudn't destroy: $list");
    }
    else {
        return $ok->()
    }
    return;
}

=head2 destroy($svc)

Removes any reference to $svc in the controller. The concerned
service must be down in the first place.

=cut

sub destroy {
    my $ctrl = shift;
    my $svc  = shift;
    my $svcname = $svc->name;
    return unless $svc->is_down;
    if ($svc->is_backoff) {
        $svc->stop;
    }
    $ctrl->log->info("Destroying service '$svcname'");
    return delete $ctrl->{servicemap}{$svcname};
}

=head2 shutdown

Cleanly exits all running commands, close all sockets etc...

=cut

sub shutdown {
    my $ctrl = shift;

    $_->down     for $ctrl->services;
    $_->shutdown for $ctrl->proxies;
    $_->unbind   for $ctrl->sockets;
}

=head1 AUTHOR

Yann Kerherve E<lt>yannk@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

I think the venerable (but hatred) daemontools is the ancestor of all
supervisor processes. In the same class there is also runit and monit.

More recent modules which inspired ControlFreak are God and Supervisord
in Python. Surprisingly I didn't find any similar program in Perl. Some
ideas in ControlFreak are subtely different though.

EDIT: I've spotted Ubic recently on CPAN

"If you have kids you probably know what I mean";
