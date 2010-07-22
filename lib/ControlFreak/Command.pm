package ControlFreak::Command;
use strict;
use warnings;

use ControlFreak::Service;
use ControlFreak::Console;
use ControlFreak::Socket;
use AnyEvent::Socket();
use Params::Util qw{ _STRING _INSTANCE _CODE };
use Carp;

=encoding utf-8

=head1 NAME

ControlFreak::Command - turn string commands to method calls

=head1 METHODS

=head2 process(%param)

Process a command from string and call either the C<ok> or the C<err>
callback with optionally a status string.

C<%param> has the following keys

=over 4

=item * cmd

The actual command string to process.

=item * ok_cb

The callback called when the command executed successfully.

=item * err_cb

The callback called when the command failed.

=item * has_priv

A boolean that if set gives access to the entire set of commands.

=item * ctrl

The controller.

=back

=cut

sub process {
    my $class = shift;
    my %param = @_;

    my $cmd = $param{cmd};
    my $ok  = $param{ok_cb}  || sub {};
    my $err = $param{err_cb} || sub {};

    if ($cmd) {
        ## clean
        $cmd =~ s/\#.*//;  # comments
        $cmd =~ s/^\s+//;  # leading whitespaces
        $cmd =~ s/\s+$//;  # trailing whitespaces
    }

    if (! $cmd) {
        if ($param{ignore_void}) {
            return;
        }
        else {
            return $err->("command is void");
        }
    }

    my ($kw, $rest) = split /\s+/, $cmd, 2;

    return $err->("empty command") unless $kw;

    my $meth = "process_$kw";
    my $h = $class->can($meth);
    return $err->("unknown command '$kw'") unless $h;

    return $h->( $class, %param, cmd => $rest );
}

sub process_service {
    my $class = shift;
    my %param = @_;

    my $cmd  = $param{cmd};
    my $ok   = $param{ok_cb} || sub {};
    my $err  = $param{err_cb} || sub {};
    my $ctrl = $param{ctrl};

    return $err->("not authorized")
        unless $param{has_priv};

    return $err->("empty service command") unless $cmd;

    my ($svcname, $attr, $assignment);
    if ($cmd =~ /^([\w-]+)\s+([\w-]+)\s*=(.*)$/) {
        $svcname     = $1;
        $attr        = $2;
        $assignment  = $3;
    }
    else {
        return $err->("malformed service command '$cmd'");
    }

    my $svc = $ctrl->find_or_create_svc($svcname)
        or return $err->("service name is invalid");

    ## Clean the value, before assigning it
    my $value = $assignment;
    if (defined $value) {
        $value =~ s/^\s+// ;

        ## DWIM with quotes
        if ($value =~ /^"(.*)"/ or $value =~ /^'(.*)'/) {
            $value = $1;
        }
    }

    if (defined $value && ! length $value) {
        $value = undef;
    }

    ## cmd is special because of the array syntax
    if ($attr eq 'cmd') {
        my $succ = $svc->set_cmd_from_con($value);
        return $succ ? $ok->($svc) : $err->("invalid value");
    }

    ## attributes existence check
    my $meth = "set_$attr";
    my $h = $svc->can($meth);
    return $err->("invalid property '$attr'")
        unless $h;

    my $success;
    if (defined $value) {
        $value = _as_bool($value) if $attr =~/ ^ ignore_std(out|err)
                                               | no_new_session
                                               | respawn_on_(fail|stop) $/x;
        $success = $h->($svc, $value);
    }
    else {
        $success = $svc->unset($attr);
    }

    return $success ? $ok->($svc) : $err->("invalid value");
}

sub process_command {
    my $class = shift;
    my %param = @_;

    my $cmd  = $param{cmd};
    my $ok   = $param{ok_cb} || sub {};
    my $err  = $param{err_cb} || sub {};
    my $ctrl = $param{ctrl};

    return $err->("empty command") unless $cmd;

    my ($command, @args) = split /\s+/, $cmd;

    return $err->("malformed service command '$cmd'")
        unless $command or @args;

    my $meth = "command_$command";
    my $h = $ctrl->can($meth);
    return $err->("unknown command '$command'") unless $h;
    $h->($ctrl, args => \@args, %param, err_cb => $err, ok_cb => $ok);
    return;
}

## FIXME: very similar to process_service
sub process_socket {
    my $class = shift;
    my %param = @_;

    my $cmd  = $param{cmd};
    my $ok   = $param{ok_cb} || sub {};
    my $err  = $param{err_cb} || sub {};
    my $ctrl = $param{ctrl};

    return $err->("not authorized")
        unless $param{has_priv};

    return $err->("empty socket command") unless $cmd;

    my ($sockname, $attr, $assignment);
    if ($cmd =~ /^([\w-]+)\s+([\w-]+)\s*=(.*)$/) {
        $sockname    = $1;
        $attr        = $2;
        $assignment  = $3;
    }
    else {
        return $err->("malformed socket command '$cmd'");
    }

    my $sock = $ctrl->find_or_create_sock($sockname)
        or return $err->("socket name is invalid");

    ## Clean the value, before assigning it
    my $value = $assignment;
    if (defined $value) {
        $value =~ s/^\s+// ;
        ## ugly (and repeated)
        $value = _as_bool($value) if $attr eq 'nonblocking';

        ## DWIM with quotes
        if ($value =~ /^"(.*)"/ or $value =~ /^'(.*)'/) {
            $value = $1;
        }
    }

    if (defined $value && ! length $value) {
        $value = undef;
    }

    ## attributes existence check
    my $meth = "set_$attr";
    my $h = $sock->can($meth);
    return $err->("invalid property '$attr'")
        unless $h;

    my $success;
    if (defined $value) {
        $success = $h->($sock, $value);
    }
    else {
        $success = $sock->unset($attr);
    }

    return $success ? $ok->($sock) : $err->("invalid value");
}

sub process_proxy {
    my $class = shift;
    my %param = @_;

    my $cmd  = $param{cmd};
    my $ok   = $param{ok_cb} || sub {};
    my $err  = $param{err_cb} || sub {};
    my $ctrl = $param{ctrl};

    return $err->("not authorized")
        unless $param{has_priv};

    return $err->("empty proxy command") unless $cmd;

    my ($proxyname, $subcmd, $rest, $attr, $assignment);
    if ($cmd =~ /^([\w-]+)\s+([\w-]+)\s+(.+)$/) {
        $proxyname = $1;
        $subcmd    = $2;
        $rest      = $3;
    }
    elsif ($cmd =~ /^([\w-]+)\s+([\w-]+)\s*=(.*)$/) {
        $proxyname  = $1;
        $attr       = $2;
        $assignment = $3;
    }
    else {
        return $err->("malformed proxy command '$cmd'");
    }

    my $proxy = $ctrl->find_or_create_proxy($proxyname)
        or return $err->("proxy name is invalid");

    if ($subcmd && $subcmd eq 'service') {
        my $svc;
        $class->process_service(
            cmd      => $rest,
            ctrl     => $ctrl,
            has_priv => 1,
            ok_cb    => sub { $svc = $_[0] },
            err_cb   => $err,
        );
        return unless $svc;
        $proxy->add_service($svc);
        return $ok->($proxy);
    }

    ## cmd is special because of the array syntax
    if ($attr eq 'cmd') {
        my $succ = $proxy->set_cmd_from_con($assignment);
        return $succ ? $ok->($proxy) : $err->("invalid value");
    }

    ## Clean the value, before assigning it
    my $value = $assignment;
    if (defined $value) {
        $value =~ s/^\s+// ;
        $value = _as_bool($value) if $attr =~ / ^noauto /x;

        ## DWIM with quotes
        if ($value =~ /^"(.*)"/ or $value =~ /^'(.*)'/) {
            $value = $1;
        }
    }

    if (defined $value && ! length $value) {
        $value = undef;
    }

    ## attributes existence check
    my $meth = "set_$attr";
    my $h = $proxy->can($meth);
    return $err->("invalid property '$attr'")
        unless $h;

    my $success;
    if (defined $value) {
        $success = $h->($proxy, $value);
    }
    else {
        $success = $proxy->unset($attr);
    }

    return $success ? $ok->($proxy) : $err->("invalid value");
}

sub _as_bool {
    my $value = shift;
    return 1 if $value =~ /^1| true| on| enabled|yes/xi;
    return 0 if $value =~ /^0|false|off|disabled| no/xi;
    return;

}

"cd&c";
