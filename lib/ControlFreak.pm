package ControlFreak;

use strict;
use 5.008_001;
our $VERSION = '0.01';

use Object::Tiny qw{
    config_file
    console
    logger
};

use Carp;
use Log::Log4perl ':easy';
Log::Log4perl->easy_init($DEBUG);
use ControlFreak::Service;
use ControlFreak::Command;
use Params::Util qw{ _ARRAY _CODE };

our $CRLF = "\015\012";

=encoding utf-8

=head1 NAME

ControlFreak - a process supervisor

=head1 SYNOPSIS

    ## see L<cvk> and L<cvkctl> manpages for how to run ControlFreak from
    ## the shell

    $ctrl = ControlFreak->new(
        config_file => $config_file,
    );
    $ctrl->run; # enter the event loop, returns only for exiting

    ## elsewhere in the eventloop
    $ctrl->add_socket($sock);
    $sock = $ctrl->socketmap->{$sockname};

    $svc = $ctrl->find_or_create($svcname);
    $ctrl->add_service($svc);
    $svc = $ctrl->service($svcname);

    @svcs = $ctrl->service_by_tag($tag);
    @svcs = $ctrl->services;

    $ctrl->destroy_service($svcname);

    $ctrl->set_console($con);
    $con = $ctrl->console;
    $log = $ctrl->logger;

    $ctrl->reload_config;

=head1 DESCRIPTION

ControlFreak is a process supervisor. It consists in a set of pure
Perl classes, a controlling process usally running in the background and
a command line tool to talk to it.

It is not a replacement for the init process, init.d etc... The initial goal
of ControlFreak is to simplify the management of all the processes required
to run a modern web application. An average web app would use:

Instances of this main L<ControlFreak> class are called controller, C<ctrl>.

=over 4

=item * Memcached

=item * A web reverse proxy or balancer, like Perlbal

=item * Multiple kind of workers

=item * A web server or an application server (apache, fastcgi, ...)

=back

More complex environments add a lot of additional services.

In production you want to tightly control those, making sure there are up
and running nominally. You also want an easy way to do code pushes and soft
roll releases.

In development you usually want to duplicate the production stack which is
a lot of services that you have to tweak and sometimes restart repeatedly, and
be able to slightly tweak based on the developer, the code branch etc...

In test, you want a few of these services, and you want to programatically
control them (making sure there are up or down)

Pid management is always a nightmare when you want to cover all these needs.

=head1 METHODS

=head2 new(%param)

=over 4

=item * config

The absolute path to a initial config file.

=back

=cut

sub new {
    my $ctrl = shift->SUPER::new(@_);

    $ctrl->{servicemap} = {};
    $ctrl->{socketmap}  = {};

    return $ctrl;
}

=head2 load_config

This should only be called once when the controller is created,
it loads the initial configuration from disk and for that reason
it's done with special privileges.

=cut

sub load_config {
    my $ctrl = shift;
    return ControlFreak::Command->from_file(
        ctrl         => $ctrl,
        file         => $ctrl->config_file,
        has_priv     => 1,
        fatal_errors => 1,
    );
}

=head2 services

returns an array of L<ControlFreak::Service> instances known to this
controller.

=cut

sub services {
    my $ctrl = shift;
    return values %{ $ctrl->{servicemap} };
}

=head2 service($name)

Return the service of name C<$name> or nothing.

=cut

sub service {
    my $ctrl = shift;
    my ($svcname) = shift or return;
    return $ctrl->{servicemap}{$svcname};
}

=head2 set_console

Take a L<ControlFreak::Console> instance in parameter and set it
has the console.

=cut

sub set_console {
    my $ctrl = shift;
    my $con = shift;

    $ctrl->{console} = $con;
    return;
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

=head2 logger

return the logger attached to the controller

=cut

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
        $err->("tags aren't supported yet");
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
    my @out = map { $_->desc_as_text } $ctrl->services;
    $ok->(join "\n", @out);
}

sub command_status {
    my $ctrl = shift;
    my %param = @_;

    my $ok = _CODE($param{ok_cb}) || sub {};
    my @svcs = $ctrl->services;
    my @out;
    for (@svcs) {
        push @out, $_->status_as_text;
    }
    $ok->(join "\n", @out);
}

## reload initial configuration
sub command_reload {
    my $ctrl  = shift;
    my %param = @_;

    INFO("Reloading initial config file");
    my $errors = 0;
    return ControlFreak::Command->from_file(
        %param,
        ctrl         => $ctrl,
        file         => $ctrl->config_file,
        has_priv     => $ctrl->console->full,
        fatal_errors => 0,
        skip_console => 1,
    );
    return;
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

=head1 WHY?

There are many similar programs freely available, but as stated above,
ControlFreak does a few things differently (and hopefully better), also having
ControlFreak written in Perl can be an important acceptance factor for some
software shop :)

=cut

"If you have kids you probably know what I mean";
