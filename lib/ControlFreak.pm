package ControlFreak;

use strict;
use 5.008_001;
our $VERSION = '0.01';

=encoding utf-8

=head1 NAME

ControlFreak - a process supervisor

=head1 SYNOPSIS

    ## see L<cvk> and L<cvkctl> manpages for how to run ControlFreak from
    ## the shell

    $cntl = ControlFreak->new(
        config => $config_file,
    );
    $cntl->run; # enter the event loop, returns only for exiting

    ## elsewhere in the eventloop
    $cntl->add_socket($sock);
    $sock = $cntl->socketmap->{$sockname};

    $cntl->add_service($svc);
    $svc = $cntl->servicemap->{$svcname};

    @svcs = $cntl->service_by_tag($tag);
    @svcs = $cntl->services;

    $cntl->destroy_service($svcname);

    my $con = $cntl->console
    $cntl->reload_config;

=head1 DESCRIPTION

ControlFreak is a process supervisor. It consists in a set of pure
Perl classes, a controlling process usally running in the background and
a command line tool to talk to it.

It is not a replacement for the init process, init.d etc... The initial goal
of ControlFreak is to simplify the management of all the processes required
to run a modern web application. An average web app would use:

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

=head1 AUTHOR

Yann Kerherve E<lt>yannk@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

=cut

"If you have kids you probably know what I mean";
