package ControlFreak::Proxy;
use strict;
use warnings;

=pod

=head1 NAME

ControlFreak::Proxy - Delegate some control to a secondary process.

=head1 DESCRIPTION

There are some cases where you want some services managed in a special way,
and it makes no sense to implement this in C<ControlFreak> itself.

Indeed, one design trait of B<ControlFreak> is its absolute simplicity, we
don't want to clutter it with features that are only rarely used or that
could make the controller unstable.

One example of that is Memory Sharing. If you have 20 application processes
running on one machine all having the same code running, then there is a
memory benefit into making sure the app is loaded in the parent process
of all these applications. Indeed, it would allow all children to initially
share parent code and thus potentially reduce the memory footprint of the
application by quite a while, maybe. But, it's out of question for the
C<controller> to load that code in its own memory. A better solution is to use
a C<ControlFreak::Proxy> separate process that will:

=over 4

=item * load the application code once and for all

=item * take commands from the main C<controller> (over pipes)

=item * fork children when instructed, that exec some user defined commands

=back

=head1 SYNOPSIS

  $proxy = ControlFreak::Proxy->new(
      ctrl => $ctrl,
      cmd  => '/usr/bin/cfk-share-mem-proxy.pl --preload Some::Module',

  );
  $proxy->add_service($svc);
  $proxy->destroy_service($svc);
  $proxy->run;
  $proxy->start_service($svc);
  $proxy->stop_service($svc);
  @list = $proxy->services;


=cut
