package ControlFreak::Command;
use strict;
use warnings;

use ControlFreak::Service;
use ControlFreak::Console;
use ControlFreak::Socket;
use AnyEvent::Socket();
use JSON::Any;
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
        my $value = _STRING($assignment);
        unless (defined $value) {
            return $err->("invalid value for console.full");
        }
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
    $h->($ctrl, args => \@args, err_cb => $err, ok_cb => $ok);
    return;
}

sub process_logger {
    my $class = shift;
    my %param = @_;

    ## TBD: not sure if this should require privileges
    my $cmd  = $param{cmd};
    my $ok   = $param{ok_cb} || sub {};
    my $err  = $param{err_cb} || sub {};
    my $ctrl = $param{ctrl};

    return $err->("empty logger") unless $cmd;

    my ($attr, $assignment);
    if ($cmd =~ /^([\w-]+)\s*=(.*)$/) {
        $attr        = $1;
        $assignment  = $2;
    }
    else {
        return $err->("malformed service command '$cmd'");
    }

    ## Clean the value, before assigning it
    my $value = $assignment;
    $value =~ s/^\s+//;
    if (defined $value && ! length $value) {
        $value = undef;
    }
    my $logger = $ctrl->log;

    ## attributes existence check
    my $meth = "set_$attr";
    my $h = $logger->can($meth);
    return $err->("invalid property '$attr'")
        unless $h;

    my $success;
    if (defined $value) {
        $success = $h->($logger, $value);
    }
    else {
        $success = $logger->unset($attr);
    }

    return $success ? $ok->() : $err->("invalid value");
    return;
}

sub _as_bool {
    my $value = shift;
    return 1 if $value =~ /^1| true| on| enabled|yes/xi;
    return 0 if $value =~ /^0|false|off|disabled| no/xi;
    return;

}

=head2 from_file(%param)

B<from_file> can be called with a number of of parameters:

=over 4

=item * ctrl

The controller. C<from_file> will croak if not passed.

=item * file

The file path.

=item * fatal_errors

A scalar evaluated in a boolean context that determines if errors
while processing the files are fatals or not.

A true value is designed to be used only at startup time.

=item * has_priv

The flag to pass to C<ControlFreak::Command> to indicate
the commands can be executed without restrictions.

=item * err_cb

The error callback as usual

=item * ok_cb

The ok callback as usual

=item * skip_console

A flag indicating that console commands should be ignored from
the file.

=back

Note, that logger config lines are processed first.

=cut

sub from_file {
    my $class = shift;
    my %param = @_;

    my $ctrl = _INSTANCE($param{ctrl}, "ControlFreak")
        or croak "ctrl param missing";

    my $ok  = _CODE($param{ok_cb})  || sub {};
    my $err = _CODE($param{err_cb}) || sub {};

    my $fatal_errors = $param{fatal_errors};
    my $wrap_err = $fatal_errors ? sub {
        my $data = shift;
        $err->($data);
        croak $data || "error";
    } : $err;

    my $cfg_file = _STRING($param{file})
        or $wrap_err->("invalid file");

    my $cfg;
    unless (open $cfg, "<", $cfg_file) {
        $wrap_err->("Error loading config: $!");
        return;
    }
    my @lines = <$cfg>;
    close $cfg;
    my @logger_lines = grep { /^\s*logger/ } @lines;

    my $line_number = 0;
    my $errors = 0;
    my $err_with_line = sub {
        my $error = shift;
        $errors++;
        $error = "line $line_number: $error";
        $err->($error);
    };

    for my $line (@logger_lines) {
        $class->process(
            cmd      => $line,
            ctrl     => $ctrl,
            ok_cb    => sub {},
            err_cb   => $err,
            has_priv => $param{has_priv},
        );
    }
    while (defined($_ = shift @lines)) {
        $line_number++;
        chomp;
        s/^\s+//;s/\s+$//;
        next if $param{skip_console} && /^console/;
        next if /^logger/;
        my $line = $_;
        next unless $line;
        $class->process(
            cmd      => $line,
            ctrl     => $ctrl,
            ok_cb    => sub {},
            err_cb   => $err_with_line,
            has_priv => $param{has_priv},
        );
    }
    $ok->() unless $errors;
    return 1;
}

"cd&c";
