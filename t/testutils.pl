use ControlFreak::Logger;
use Time::HiRes qw/gettimeofday tv_interval/;

{
    no warnings 'redefine';
    *ControlFreak::Logger::default_config = sub { \<<EOL
    log4perl.rootLogger=DEBUG, SCREEN
    log4perl.appender.SCREEN=Log::Log4perl::Appender::Screen
    log4perl.appender.SCREEN.layout=SimpleLayout
EOL
    };
}

sub wait_for_starting { wait_for_status('is_starting', @_) }
sub wait_for_running  { wait_for_status('is_running', @_) }
sub wait_for_down     { wait_for_status('is_down', @_) }
sub wait_for_fail     { wait_for_status('is_fail', @_) }
sub wait_for_fatal    { wait_for_status('is_fatal', @_) }
sub wait_for_stopping { wait_for_status('is_stopping', @_) }
sub wait_for_stopped  { wait_for_status('is_stopped', @_) }
sub wait_for_backoff  { wait_for_status('is_backoff', @_) }

sub wait_for_status {
    my $cond = shift;
    my $svc = shift;
    my $max_wait = shift || 1;
    #wait_for(sub { warn $svc->name . $svc->state; $svc->$cond }, $max_wait);
    wait_for(sub { $svc->$cond }, $max_wait);
}

sub shutoff_logs {
    no warnings 'redefine';
    *ControlFreak::Logger::default_config = sub { \<<EOL
log4perl.rootLogger=DEBUG, NULL
log4perl.appender.NULL=Log::Log4perl::Appender::Screen
log4perl.appender.NULL.layout=SimpleLayout
log4perl.appender.NULL.Threshold = OFF
EOL
    };
}

sub wait_for {
    my $coderef = shift;
    my $max_wait = shift || 1;

    my $iv = 0.05;
    my $stopped = AE::cv;
    my $t0 = [gettimeofday];
    my $w; $w = AE::timer 0, $iv, sub {
        my $timeout = tv_interval($t0) > $max_wait;
        if ($coderef->() or $timeout) {
            $stopped->send(!$timeout);
            undef $w;
        }
    };
    return $stopped->recv;
}

1;
