package # hide from CPAN indexer
    t::helper;
use strict;
use Test::More;
use File::Glob qw(bsd_glob);
use Config '%Config';
use File::Spec;
use Carp qw(croak);
use File::Temp 'tempdir';
use WWW::Mechanize::Chrome;
use Config;
use Time::HiRes qw(sleep time);
use POSIX qw(:sys_wait_h);

use Log::Log4perl ':easy';

delete $ENV{HTTP_PROXY};
delete $ENV{HTTPS_PROXY};
$ENV{PERL_FUTURE_DEBUG} = 1
    if not exists $ENV{PERL_FUTURE_DEBUG};

# Global PID tracking for fail-safe cleanup
our %all_spawned_pids;
{
    my $org_new = \&WWW::Mechanize::Chrome::new;
    no warnings 'redefine';
    *WWW::Mechanize::Chrome::new = sub {
        my $self = $org_new->(@_);
        if (ref $self && $self->{pid}) {
            for my $pid ($self->{pid}->@*) {
                $all_spawned_pids{$pid} = 1 if $pid;
            }
        }
        return $self;
    };

    # Override kill_child to be more aggressive and non-blocking in tests.
    # This prevents hangs during the cleanup phase of tests, especially with
    # modern Chromium versions that may not exit promptly on SIGTERM.
    *WWW::Mechanize::Chrome::kill_child = sub {
        my ($self, $signal, $pids, $wait_file) = @_;
        return unless $pids;

        my @p = ref $pids eq 'ARRAY' ? @$pids : ($pids);

        for my $pid (@p) {
            next unless $pid && kill(0, $pid);

            # Use SIGKILL in tests to ensure swift termination and avoid hangs
            kill('KILL', $pid);

            # Non-blocking wait with a short timeout
            my $timeout = Time::HiRes::time() + 2;
            while (Time::HiRes::time() < $timeout) {
                my $res = waitpid($pid, WNOHANG);
                last if $res == -1 || $res == $pid;
                Time::HiRes::sleep(0.1);
            }

            delete $all_spawned_pids{$pid};
        }
        return;
    };

}

END {
    # Final fail-safe cleanup of all PIDs spawned during this test process
    for my $pid (keys %all_spawned_pids) {
        if ($pid && kill(0, $pid)) {
            kill('KILL', $pid);
            waitpid($pid, WNOHANG);
        }
    }
}

sub need_minimum_chrome_version {
    my( $version, @args ) = @_;
    $version =~ m!^(\d+)\.(\d+)\.(\d+)\.(\d+)$!
        or croak "Invalid version parameter '$version'";
    my( $need_maj, $need_min, $need_sub, $need_patch ) = ($1,$2,$3,$4);

    my $v = WWW::Mechanize::Chrome->chrome_version( @args );
    $v =~ m!/(\d+)\.(\d+)\.(\d+)\.(\d+)$!
        or die "Couldn't find version info from '$v'";
    my( $maj, $min, $sub, $patch ) = ($1,$2,$3,$4);
    if(    $maj < $need_maj
        or $maj == $need_maj and $min < $need_min
        or $maj == $need_maj and $min == $need_min and $sub < $need_sub
        or $maj == $need_maj and $min == $need_min and $sub == $need_sub and $patch < $need_patch
    ) {
        croak "Chrome $v is unsupported. Minimum required version is $version.";
    };
    return;
};

sub browser_instances {
    my ($filter) = @_;
    $filter ||= qr/^/;

    # (re)set the log level
    if (my $lv = $ENV{TEST_LOG_LEVEL}) {
        if( $lv eq 'trace' ) {
            Log::Log4perl->easy_init($TRACE)
        } elsif( $lv eq 'debug' ) {
            Log::Log4perl->easy_init($DEBUG)
        }
    }

    my @instances;

    if( $ENV{TEST_WWW_MECHANIZE_CHROME_INSTANCE}) {
        push @instances, $ENV{TEST_WWW_MECHANIZE_CHROME_VERSIONS};

    } elsif( $ENV{TEST_WWW_MECHANIZE_CHROME_VERSIONS} ) {
        # add author tests with local versions
        my $spec = $ENV{TEST_WWW_MECHANIZE_CHROME_VERSIONS};
        push @instances, grep { -x } bsd_glob $spec;

    } elsif( $ENV{CHROME_BIN}) {
        push @instances, $ENV{ CHROME_BIN }
            if $ENV{ CHROME_BIN } and -x $ENV{ CHROME_BIN };

    } else {
        my ($default) = WWW::Mechanize::Chrome->find_executable();
        push @instances, $default
            if $default;
        my $spec = 'chrome-versions/*/{*/,}chrome' . $Config{_exe}; # sorry, likely a bad default
        push @instances, grep { -x } bsd_glob $spec;
    };

    # Consider filtering for unsupported Chrome versions here
    @instances = map { s!\\!/!g; $_ } # for Windows
                 grep { ($_ ||'') =~ /$filter/ } @instances;

    # Only use unique Chrome executables
    my %seen;
    @seen{ @instances } = 1 x @instances;

    # Well, we should do a nicer natural sort here
    @instances = sort {$a cmp $b} keys %seen;
    return @instances;
};

sub default_unavailable {
    return !scalar browser_instances;
};

sub runtests {
    my ($browser_instance, $new_mech, $code, $test_count) = @_;
    #if ($browser_instance) {
    #    note sprintf 'Testing with %s',
    #        $browser_instance;
    #};
    my $tempdir = tempdir( CLEANUP => 1 );
    my @launch;
    if( $ENV{TEST_WWW_MECHANIZE_CHROME_INSTANCE} ) {
        my( $host, $port ) = split /:/, $ENV{TEST_WWW_MECHANIZE_CHROME_INSTANCE};
        @launch = ( host => $host,
                    port => $port,
                    reuse => 1,
                    new_tab => 1,
                  );
    } else {
        @launch = ( launch_exe => $browser_instance,
                    #port => $port,
                    data_directory => $tempdir,
                    headless => 1,
                  );
    };

    {
        my $mech = eval { $new_mech->(@launch) };
        if( ! $mech ) {
            my $err = $@;
            SKIP: {
                skip "Couldn't create new object: $err", $test_count;
            };
            my $version = eval {
                WWW::Mechanize::Chrome->chrome_version(
                    launch_exe => $browser_instance
                );
            };
            diag sprintf "Failed on Chrome version '%s': %s", ($version || '(unknown)'), $err;
            return;
        };

        note sprintf "Using Chrome version '%s'",
            $mech->chrome_version;

        # Run the user-supplied tests, making sure we don't keep a
        # reference to $mech around
        @_ = ($browser_instance, $mech);
    };

    # Ensure stack frame is cleared to allow proper destruction
    goto &$code;
}

sub run_across_instances {
    #my ($instances, $new_mech, $test_count, $code) = @_;

    croak 'No test count given'
        unless $_[2]; #$test_count;

    for my $browser_instance (@{$_[0]}) {
        runtests( $browser_instance, @_[1,3,2] );
    };
    return;
};

sub safe_xpath {
    my ($mech, $query, %options) = @_;
    my $timeout = delete $options{timeout} || 5;
    my $start = Time::HiRes::time();
    my $wantarray = wantarray;
    my $call_f = $mech->xpath_future($query, %options);
    my $timeout_f = $mech->sleep_future($timeout)->then(sub { Future->fail("Timeout during xpath search for $query") });
    my $f = Future->wait_any($call_f, $timeout_f);
    my $elapsed = Time::HiRes::time() - $start;
    if ($elapsed > 0.1) {
        Test::More::note(sprintf('xpath("%s") took %.3fs', $query, $elapsed));
    }
    if ($wantarray) {
        return $f->get;
    } else {
        my @res = $f->get;
        return $res[0];
    }
}

sub safe_get {
    my ($mech, $url, %options) = @_;
    my $timeout = delete $options{timeout} || 10;
    my $start = Time::HiRes::time();
    my $wantarray = wantarray;
    my $call_f = $mech->get_future($url, %options);
    my $timeout_f = $mech->sleep_future($timeout)->then(sub { Future->fail("Timeout during navigation to $url") });
    my $f = Future->wait_any($call_f, $timeout_f);
    my $elapsed = Time::HiRes::time() - $start;
    if ($elapsed > 0.1) {
        Test::More::note(sprintf('get("%s") took %.3fs', $url, $elapsed));
    }
    if ($wantarray) {
        return $f->get;
    } else {
        my @res = $f->get;
        return $res[0];
    }
}

sub safe_value {
    my ($mech, @args) = @_;
    my %options;
    if (ref $args[-1] eq 'HASH') {
        %options = %{pop @args};
    }
    my $timeout = delete $options{timeout} || 5;
    my $name = shift @args;
    my $index = shift @args;

    my $start = Time::HiRes::time();
    my $wantarray = wantarray;
    my $call_f = $mech->get_set_value_future(
        name => $name,
        index => $index,
        node => $mech->current_form,
        %options
    );
    my $timeout_f = $mech->sleep_future($timeout)->then(sub { Future->fail("Timeout during value retrieval") });
    my $f = Future->wait_any($call_f, $timeout_f);
    my $elapsed = Time::HiRes::time() - $start;
    if ($elapsed > 0.1) {
        Test::More::note(sprintf('value("%s") took %.3fs', $name, $elapsed));
    }
    if ($wantarray) {
        return $f->get;
    } else {
        my @res = $f->get;
        return $res[0];
    }
}

sub safe_field {
    my ($mech, $name, $value, @args) = @_;
    my %options;
    if (@args and ref $args[-1] eq 'HASH') {
        %options = %{pop @args};
    }
    my $timeout = delete $options{timeout} || 5;
    my $index = shift @args;

    my $start = Time::HiRes::time();
    my $wantarray = wantarray;
    my $call_f = $mech->field_future($name, $value, $index, @args);
    my $timeout_f = $mech->sleep_future($timeout)->then(sub { Future->fail("Timeout during field setting") });
    my $f = Future->wait_any($call_f, $timeout_f);
    my $elapsed = Time::HiRes::time() - $start;
    if ($elapsed > 0.1) {
        Test::More::note(sprintf('field("%s") took %.3fs', $name, $elapsed));
    }
    if ($wantarray) {
        return $f->get;
    } else {
        my @res = $f->get;
        return $res[0];
    }
}

sub safe_set_fields {
    my ($mech, %fields) = @_;
    my $timeout = 5;
    my $start = Time::HiRes::time();
    my $call_f = $mech->set_fields_future(%fields);
    my $timeout_f = $mech->sleep_future($timeout)->then(sub { Future->fail("Timeout during set_fields") });
    my $f = Future->wait_any($call_f, $timeout_f);
    my $res = $f->get;
    my $elapsed = Time::HiRes::time() - $start;
    if ($elapsed > 0.1) {
        Test::More::note(sprintf('set_fields took %.3fs', $elapsed));
    }
    return $res;
}

sub safe_content {
    my ($mech, %options) = @_;
    my $timeout = delete $options{timeout} || 10;
    my $start = Time::HiRes::time();
    my $call_f = $mech->content_future(%options);
    my $timeout_f = $mech->sleep_future($timeout)->then(sub { Future->fail("Timeout during content retrieval") });
    my $f = Future->wait_any($call_f, $timeout_f);
    my $res = $f->get;
    my $elapsed = Time::HiRes::time() - $start;
    if ($elapsed > 0.1) {
        Test::More::note(sprintf('content() took %.3fs', $elapsed));
    }
    return $res;
}

sub safe_decoded_content {
    my ($mech, %options) = @_;
    my $timeout = delete $options{timeout} || 10;
    my $start = Time::HiRes::time();
    my $call_f = $mech->decoded_content_future();
    my $timeout_f = $mech->sleep_future($timeout)->then(sub { Future->fail("Timeout during decoded_content retrieval") });
    my $f = Future->wait_any($call_f, $timeout_f);
    my $res = $f->get;
    my $elapsed = Time::HiRes::time() - $start;
    if ($elapsed > 0.1) {
        Test::More::note(sprintf('decoded_content() took %.3fs', $elapsed));
    }
    return $res;
}

sub set_watchdog {
    my ($timeout_s) = @_;
    my $name = (caller(1))[3] || 'Test';
    $SIG{ALRM} = sub { 
        Test::More::note("$name timed out after ${timeout_s}s!"); 
        CORE::exit(1);
    };
    if( $^O =~ /mswin/i ) {
        alarm($timeout_s);
    } else {
        # Use ualarm for sub-second precision if needed, but here we take seconds
        Time::HiRes::ualarm($timeout_s * 1_000_000);
    }
}

1;
