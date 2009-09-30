package ControlFreak::Service;
use strict;
use warnings;

use Object::Tiny qw{
    name
    desc

    state
    child_cv
    start_time

    cmd
    running_cmd
    env
    cwd
    stdin
    tags
    ignore_stderr
    ignore_stdout
    start_secs
    stopwait_secs
    user
    group
    priority
};

=encoding utf-8

=head1 NAME

ControlFreak::Service - Object representation of a service.

=head1 SYNOPSIS

    my $mc = ControlFreak::Service->new(
        name => "memcached",
        desc => "you should have this one...",
        ignore_stderr => 1,
        cmd => "/usr/bin/memcached",
    );

    my $fcgisock = $cntl->socketmap->{fcgi};
    my $web = ControlFreak::Service->new(
        name => "fcgi",
        desc => "I talk http",
        stdin => $fcgisock,
        cmd => "/usr/bin/plackup -a MyApp -s FCGI",
    );
    $web->up;
    $web->start;
    $web->stop;

    ## A service can mutate
    $web->add_tag('prod');

    ## all set_* accessors are callable from Commands
    $web->set_cmd("/usr/bin/plackup -a MyNewApp");
    $web->set_ignore_stderr(0);
    # ...

    $web->running_cmd;

=head1 DESCRIPTION

This allow manipulation of a service and its state.

=head1 AUTHOR

Yann Kerherve E<lt>yannk@cpan.orgE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<ControlFreak>

=cut

1;
