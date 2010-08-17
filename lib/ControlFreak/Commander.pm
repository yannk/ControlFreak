package ControlFreak::Commander;
use strict;
use warnings;
use Socket qw($CRLF);
use Carp;

our $has_datetime;
our $has_ansi;
our $can_color;

BEGIN {
    $has_datetime = eval "use DateTime; 1";
    $has_ansi     = eval "use Term::ANSIColor; 1";
    $can_color    = -t STDOUT;
};

sub new {
    my $class = shift;
    return bless { @_ }, $class,
};

sub send_request {
    my $commander = shift;
    my $request = shift;
    my $socket = $commander->{socket};
    $socket->print("$request$CRLF");
}

sub cmd_list {
    my $commander = shift;
    $commander->send_request("command list");
    my ($error, $response) = $commander->read_response;
    croak "error: $error" if $error;
    return join "\n", @$response;
}

sub cmd_version {
    my $commander = shift;
    $commander->send_request("command version");
    my ($error, $response) = $commander->read_response;
    croak "error: $error" if $error;
    return join "\n", @$response;
}

sub send_status_req {
    my $commander = shift;
    my $arg = shift;
    my $statuses = shift;
    $commander->send_request("command status $arg");
    my ($error, $response) = $commander->read_response;
    if ($error) {
        warn "error: $error";
        next;
    }
    $commander->parse_statuses($response, $statuses);
}

sub cmd_status {
    my $commander = shift;
    my @args      = parse_svcs(@_);

    my %statuses;
    @args = ('all') unless @args;
    for (@args) {
        $commander->send_status_req($_, \%statuses);
    }
    my @out;
    for my $svcname (keys %statuses) {
        my %st = %{$statuses{$svcname}};
        my ($uptime, $time);
        if ($st{start_time} && $st{stop_time}) {
            if ($st{start_time} >= $st{stop_time}) {
                $uptime = $st{uptime};
                $time   = $st{str_start_time};
            }
            else {
                $uptime = $st{downtime};
                $time   = $st{str_stop_time};
            }
        }
        elsif ($st{start_time}) {
            $uptime = $st{uptime};
            $time   = $st{str_start_time};
        }
        elsif ($st{stop_time}) {
            $uptime = $st{downtime};
            $time   = $st{str_stop_time};
        }

        $uptime ||= "";
        $time   ||= "";
        if ($time) {
            push @out, sprintf("%-8s %-20s %15s (%s)",
                    $statuses{$svcname}{status},
                    $svcname,
                    $uptime,
                    $time
                );
        }
        else {
            push @out, sprintf("%-8s %-30s",
                $statuses{$svcname}{status},
                $svcname,
            );
        }
    }
    return join "\n", @out;
}

sub cmd_proxystatus {
    my $commander = shift;
    $commander->send_request("command proxystatus");

    my $do_color  = $can_color && $has_ansi;

    my ($error, $response) = $commander->read_response;
    if ($error) {
        warn "error: $error";
        next;
    }
    my @out;
    for (reverse @$response) {
        my %st;
        @st{ qw/name status pid/ } = split /\t/, $_;

        my $string_status = my $status = $st{status};

        if ($do_color) {
            my $color;
            if ($status eq "up") {
                $color = "bold green";
            }
            else {
                $color = "bold red";
            }
            $string_status = color($color) . $status . color('reset');
        }
        push @out, sprintf "%-6s %-20s %6s", $string_status,
                                             $st{name},
                                             ($st{pid} || "");
    }
    return join "\n", @out;
}

sub parse_statuses {
    my $commander = shift;
    my ($response, $statuses) = @_;

    my $do_color  = $can_color && $has_ansi;

    for (reverse @$response) {
        my %st;
        @st{ qw/svcname status pid start_time stop_time
                proxy fail_reason running_cmd/ } = split /\t/, $_;

        ## remove duplicates
        next if defined $statuses->{ $st{svcname} };

        my $status = $st{status};
        my $string_status = $status;
        if ($do_color) {
            my $color;
            $color = "bold green"  if $status =~ /(starting|running)/;
            $color = "bold yellow" if $status =~ /(stopping|stopped)/;
            $color = "bold red"    if $status =~ /(fail|backoff|fatal)/;
            $string_status = color($color) . $status . color('reset');
        }
        my $name = $st{svcname};
        $statuses->{$name} = \%st;

        $statuses->{$name}{status}     = $string_status;
        $statuses->{$name}{uptime}     = _reltime( $st{start_time} );
        $statuses->{$name}{downtime}   = _reltime( $st{stop_time}  );
        $statuses->{$name}{str_start_time} = scalar localtime( $st{start_time} )
            if $st{start_time};
        $statuses->{$name}{str_stop_time}  = scalar localtime( $st{stop_time} )
            if $st{stop_time};
    }
}

sub _reltime {
    my $time = shift;
    return unless $time;
    return unless $has_datetime;
    my $now  = DateTime->now(time_zone => 'floating');
    my $past = DateTime->from_epoch( epoch => $time, time_zone => 'floating' );

    my $today = $now->truncate(to => 'days')->add( days => 1 );

    my $days  = $today - $past;
    my $ddur  = $days->in_units('days');

    if ( $ddur > 2 ) {
        return sprintf "%2d days ago", $ddur;
    }
    elsif ( $ddur <= 1 ) {
        my $dur = $now - $past;
        my $hdur = $dur->in_units('hours');
        if ($hdur >= 1) {
            return sprintf "%2d hours ago", $hdur;
        }
        my $mdur = $dur->in_units('minutes');
        if ($mdur >= 1) {
            return sprintf "%2d minutes ago", $mdur;
        }
        my $sdur = $dur->in_units('seconds');
        return sprintf "%2d seconds ago", $sdur;
    }
    elsif ( $ddur > 1 ) {
        return "yesterday";
    }
    else { return "what??"; }
}

sub cmd_desc {
    my $commander = shift;
    my @svcrefs   = @_;
    @svcrefs = ('all') unless @svcrefs;
    my @arguments = parse_svcs(@svcrefs);
    my %desc;
    for (@arguments) {
        $commander->send_request("command desc $_");
        my ($error, $response) = $commander->read_response;
        croak "error: $error" if $error;
        for (@$response) {
            my @p = map { s/"/\\"/g; $_ } split /\t/, $_;
            my $svcname = shift @p;
            $desc{$svcname} = {
                tags  => $p[0],
                desc  => $p[1],
                proxy => $p[2],
                cmd   => $p[3],
            };
        }
    }
    my @outer_out;
    for (keys %desc) {
        my %d   = %{$desc{$_}};
        my @out = ("$_:");
        push @out, "tags=\"$d{tags}\""   if $d{tags};
        push @out, "desc=\"$d{desc}\""   if $d{desc};
        push @out, "proxy=\"$d{proxy}\"" if $d{proxy};
        push @out, "cmd=\"$d{cmd}\""     if $d{cmd};
        push @outer_out, join " ", @out;
    }
    return join "\n", @outer_out;
}

sub cmd_pid {
    my $commander = shift;
    my $svc = shift or return;
    my %st;
    $commander->send_status_req("service $svc", \%st);
    my $pid = $st{$svc}{pid};
    return $pid if $pid;
    return;
}

sub cmd_pids {
    my $commander = shift;
    my @svcrefs   = @_;
    @svcrefs = ('all') unless @svcrefs;
    my @arguments = parse_svcs(@svcrefs);
    my %st;
    for (@arguments) {
        $commander->send_status_req($_, \%st);
    }
    my @out;
    for my $svcname (keys %st) {
        my $pid = $st{$svcname}{pid} || "";
        push @out, "$svcname: $pid";
    }
    return join "\n", @out;
}

sub cmd_shutdown {
    my $commander = shift;
    $commander->send_request("command shutdown");
    return '';
}

sub cmd_up      { _cmd_svc( "up",      @_ ) }
sub cmd_down    { _cmd_svc( "down",    @_ ) }
sub cmd_stop    { _cmd_svc( "stop",    @_ ) }
sub cmd_start   { _cmd_svc( "start",   @_ ) }
sub cmd_restart { _cmd_svc( "restart", @_ ) }
sub cmd_destroy { _cmd_svc( "destroy", @_ ) }

sub cmd_proxyup   { _cmd_proxy( "up",   @_ ) }
sub cmd_proxydown { _cmd_proxy( "down", @_ ) }

sub _cmd_svc {
    my $command   = shift;
    my $commander = shift;
    my @svcrefs   = @_;

    my @arguments = parse_svcs(@svcrefs);
    for (@arguments) {
        $commander->send_request("command $command $_");
        my ($error) = $commander->read_response;
        if ($error) {
            croak "error: $error";
        }
    }
}

sub _cmd_proxy {
    my $command   = shift;
    my $commander = shift;
    my ($proxy)   = @_;

    $commander->send_request("command proxy$command $proxy");
    my ($error) = $commander->read_response;
    if ($error) {
        croak "error: $error";
    }
}

sub cmd_load {
    my $commander = shift;
    my ($file) = @_;

    my $base = $commander->{basedir}
             || File::Spec->rel2abs(File::Spec->curdir);
    unless (defined $file && length $file) {
        croak "please specify a file to load";
    }
    my $fh;
    if ($file eq '-') {
        $fh = *STDIN;
    }
    else {
        unless (-f $file && -r _) {
            croak "Error, file '$file' is not readable";
        }
        open $fh, "<$file" or croak "Cannot open '$file': $!";
    }
    while (<$fh>) {
        chomp;
        next unless /\S/;   # skip empty lines (void commands)
        next if /^\s*#/;    # skip comments (void commands)
        s/\${BASE}/$base/;  # substitute configured base
        $commander->send_request($_);
        my ($error) = $commander->read_response;
        if ($error) {
            croak "error: $error";
        }
    }
    close $fh unless $file eq '-';
    return '';
}

sub read_response {
    my $commander = shift;
    my $socket = $commander->{socket};
    my @response;
    my $error;
    while (<$socket>) {
        last unless defined;
        last if /^OK$CRLF/;
        if (/^ERROR: (.*)$CRLF/) {
            $error = $1;
            last;
        }
        chomp;
        push @response, $_;
    }
    return ($error, \@response);
}

sub parse_svcs {
    my @args = @_;

    my @parsed;

    for (@args) {
        if ($_ eq 'all') {
            return ('all');
        }
        if (/^@(.*)$/) {
            push @parsed, "tag $1";
        }
        else {
            push @parsed, "service $_";
        }
    }
    return @parsed;
}

sub exit {
    my $commander = shift;
    $commander->send_request("exit");
    $commander->{socket}->close;
}

1;
