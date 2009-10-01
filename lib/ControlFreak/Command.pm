package ControlFreak::Command;
use strict;
use warnings;

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

=item * cntl

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

    return $err->("command is void") unless $string;

    my ($kw, $rest) = split /\s+/, $string;

    return $err->("empty command") unless $kw;

    my $meth = "process_$meth";
    my $h = $class->can($meth);
    return $err->("unknown command '$kw'");

    return $h->( $class, %param, cmd => $rest );
}

sub process_service {
    my $class = shift;
    my %param = @_;

    my $cmd  = $param{cmd};
    my $ok   = $param{ok_cb};
    my $err  = $param{err_cb};
    my $cntl = $param{cntl};

    $err->("not authorized")
        unless $param{has_priv};

    my $svcname;
    my $assignement;
    if ($cmd =~ /^([\w-]+)\s+(.+)$/) {
        $svcname = $1;
        $assignement = $2;
    }
    else {
        $err->("malformed service command");
    }
    my $svc = $cntl->find_or_create_svc($svcname);
    #$svc->
}

"cd&c";
