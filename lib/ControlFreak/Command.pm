package ControlFreak::Command;
use strict;
use warnings;

use ControlFreak::Service;
use ControlFreak::Console;
use ControlFreak::Socket;
use Params::Util qw{ _IDENTIFIER };

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

sub process_service {
    my $class = shift;
    my %param = @_;

    my $cmd  = $param{cmd};
    my $ok   = $param{ok_cb};
    my $err  = $param{err_cb};
    my $ctrl = $param{ctrl};

    return $err->("not authorized")
        unless $param{has_priv};

    return $err->("empty service command") unless $cmd;

    my ($svcname, $attr, $assignement);
    if ($cmd =~ /^([\w-]+)\s+([\w-]+)\s*=(.*)$/) {
        $svcname     = $1;
        $attr        = $2;
        $assignement = $3;
    }
    else {
        return $err->("malformed service command $cmd");
    }

    my $svc = $ctrl->find_or_create_svc($svcname)
        or return $err->("service name is invalid");

    ## attributes existence check
    my $meth = "set_$attr";
    my $h = $svc->can($meth);
    return $err->("invalid property '$attr'")
        unless $h;

    ## Clean the value, before assigning it
    my $success;
    my $value = $assignement;
    $value =~ s/^\s+//;
    if (defined $value && ! length $value) {
        $value = undef;
    }
    if (defined $value) {
        $success = $h->($svc, $value);
    }
    else {
        $success = $svc->unset($attr);
    }

    return $success ? $ok->() : $err->("invalid value");
}

"cd&c";
