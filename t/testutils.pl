sub wait_for_starting { wait_for_status('is_starting', @_) }
sub wait_for_down     { wait_for_status('is_down', @_) }
sub wait_for_fail     { wait_for_status('is_fail', @_) }

sub wait_for_status {
    my $cond = shift;
    my $svc = shift;
    my $max_wait = shift || 1;
    my $iv = 0.05;
    my $stopped = AE::cv;
    my $t0 = [gettimeofday];
    my $w; $w = AE::timer 0, $iv, sub {
        my $timeout = tv_interval($t0) > $max_wait;
        if ($svc->$cond or $timeout) {
            $stopped->send(!$timeout);
            undef $w;
        }
    };
    return $stopped->recv;
}
1;
