package ControlFreak::Command;
use strict;
use warnings;

use ControlFreak::Service;
use ControlFreak::Console;
use ControlFreak::Socket;
use AnyEvent::Socket();
use JSON::Any;
use Params::Util qw{ _STRING };

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

    return $err->("empty command") unless $cmd;

    ## clean
    $cmd =~ s/\#.*//;  # comments
    $cmd =~ s/^\s+//;  # leading whitespaces
    $cmd =~ s/\s+$//;  # trailing whitespaces

    return $err->("command is void") unless $cmd;

    my ($kw, $rest) = split /\s+/, $cmd, 2;

    return $err->("empty command") unless $kw;

    my $meth = "process_$kw";
    my $h = $class->can($meth);
    return $err->("unknown command '$kw'") unless $h;

    return $h->( $class, %param, cmd => $rest );
}

sub process_console {
    my $class = shift;
    my %param = @_;

    my $cmd  = $param{cmd};
    my $ok   = $param{ok_cb} || sub {};
    my $err  = $param{err_cb} || sub {};
    my $ctrl = $param{ctrl};

    my $console = $ctrl->console;
    return $err->("there is a console already")
        if $console && $console->started;

    unless ($console) {
        $console = ControlFreak::Console->new(ctrl => $ctrl);
    }

    return $err->("not authorized")
        unless $param{has_priv};

    my ($attr, $assignment);
    if ($cmd =~ /^([\w-]+)\s*=\s*(\S+)$/) {
        $attr       = $1;
        $assignment = $2 || "";
    }
    else {
        return $err->("malformed console command '$cmd'");
    }

    my $success = 1;
    if ($attr eq 'address') {
        my $addr = $assignment;
        $addr =~ s/\s//g if $addr;
        return $err->("invalid address: '$assignment'") unless $addr;
        my ($host, $service) =
            AnyEvent::Socket::parse_hostport($addr, '8888');

        return $err->("cannot parse address '$assignment'") unless $host;
        $console->{host} = $host;
        $console->{service} = $service;
        $success = 1;
    }
    if ($attr eq 'full') {
        my $value = _STRING($assignment)
            or return $err->("invalid value for console.full");
        return $err->("incorrect boolean for console.full")
            unless defined ($value = _as_bool($value));
        $console->{full} = $value;
    }

    return $ok->() if $success;
    return $err->("unknown console attribute: '$attr'");
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
    $value =~ s/^\s+//;
    if (defined $value && ! length $value) {
        $value = undef;
    }

    ## cmd is special because of the array syntax
    if ($attr eq 'cmd') {
        my $succ = $svc->set_cmd_from_con($value);
        return $succ ? $ok->() : $err->("invalid value");
    }

    ## attributes existence check
    my $meth = "set_$attr";
    my $h = $svc->can($meth);
    return $err->("invalid property '$attr'")
        unless $h;

    my $success;
    if (defined $value) {
        $success = $h->($svc, $value);
    }
    else {
        $success = $svc->unset($attr);
    }

    return $success ? $ok->() : $err->("invalid value");
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
    $h->($ctrl, @args);

    return $ok->();
#    return $success ? $ok->() : $err->("invalid value");
}

sub _as_bool {
    return 1 if /^1| true| on| enabled|yes/xi;
    return 0 if /^0|false|off|disabled| no/xi;
    return;

}

"cd&c";
