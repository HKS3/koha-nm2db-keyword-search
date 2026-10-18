#!/usr/bin/perl

use Modern::Perl;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More;
use Test::MockModule;
use CGI;
use Koha::Plugin::HKS3::NM2DBKeywordSearch;
use Koha::Plugin::HKS3::NM2DBKeywordSearch::Jobs::RefreshCache;

my $plugin_class = 'Koha::Plugin::HKS3::NM2DBKeywordSearch';
my $job_class = $plugin_class . '::Jobs::RefreshCache';
my $context = Test::MockModule->new('C4::Context');
$context->mock( dbh => sub { die 'Unexpected database access' } );
my $plugin_mock = Test::MockModule->new($plugin_class);
my $job_mock = Test::MockModule->new($job_class);

subtest 'job registration and enqueue' => sub {
    my $plugin = bless {}, $plugin_class;
    my $tasks = $plugin->background_tasks;
    is( $tasks->{refresh_cache}->{class}, $job_class, 'registers the refresh job class' );
    is( $job_class->job_type, 'plugin_nm2db_keyword_search_refresh_cache',
        'job type matches namespace plus registered task' );
    my $base = Test::MockModule->new('Koha::BackgroundJob');
    my $params;
    $base->mock( enqueue => sub { $params = $_[1]; return 37 } );
    is( $job_class->new->enqueue, 37, 'returns the enqueued job ID' );
    is_deeply( $params, { job_size => 1, job_args => {}, job_queue => 'long_tasks' },
        'full refresh uses the long-running queue without user-controlled arguments' );
    done_testing;
};

subtest 'tool only starts a refresh with POST and a valid CSRF token' => sub {
    my $template = bless {}, 'RefreshCacheTestTemplate';
    my $template_file;
    $plugin_mock->mock( get_template => sub { $template_file = $_[1]->{file}; return $template } );
    $plugin_mock->mock( output_html => sub { } );
    my $calls = 0;
    $job_mock->mock( enqueue => sub { $calls++; return 37 } );
    my $token = Test::MockModule->new('Koha::Token');
    my $valid = 1;
    $token->mock( check_csrf => sub { return $valid } );

    for my $case (
        [ 'GET', q{}, 1, 0 ],
        [ 'GET', 'cud-refresh-cache', 1, 0 ],
        [ 'POST', 'cud-refresh-cache', 0, 0 ],
        [ 'POST', 'cud-refresh-cache', 1, 1 ],
    ) {
        my ( $method, $op, $csrf_valid, $expected ) = @{$case};
        local $ENV{REQUEST_METHOD} = $method;
        my $cgi = CGI->new( { method => 'tool', op => $op, csrf_token => 'test-token' } );
        my $plugin = bless { cgi => $cgi }, $plugin_class;
        $valid = $csrf_valid;
        my $before = $calls;
        my $output = q{};
        open my $handle, '>', \$output or die $!;
        my $ok;
        { local *STDOUT = $handle; $ok = eval { $plugin->tool; 1 }; }
        is( $calls - $before, $expected, "$method/$op (CSRF=$valid): expected enqueue count" );
        if ($expected) {
            ok( $ok, 'valid POST succeeds' );
            like( $output, qr/Status: 303/, 'uses POST/redirect/GET' );
            like( $output, qr/background_jobs\.pl\?op=view&id=37/, 'redirects to the job details' );
        } elsif ($op) {
            ok( !$ok, 'unsafe refresh is rejected' );
        } else {
            ok( $ok, 'ordinary GET renders the maintenance page' );
            is( $template_file, 'tool.tt', 'tool uses the maintenance-only template' );
            ok( !exists $template->{api_search_url}, 'tool does not pass a search API URL' );
        }
    }

    local $ENV{REQUEST_METHOD} = 'POST';
    my $cgi = CGI->new( { op => 'cud-refresh-cache' } );
    my $plugin = bless { cgi => $cgi }, $plugin_class;
    $valid = 1;
    $job_mock->mock( enqueue => sub { die "Test enqueue failure\n" } );
    local $SIG{__WARN__} = sub { };
    $plugin->tool;
    ok( $template->{refresh_error}, 'enqueue failure is shown on the tool page' );
    done_testing;
};

subtest 'tool template retains refresh but no keyword search UI' => sub {
    open my $handle, '<', "$Bin/../Koha/Plugin/HKS3/NM2DBKeywordSearch/tool.tt" or die $!;
    my $template = do { local $/; <$handle> };
    like( $template, qr/<form method="post"/, 'refresh remains a POST form' );
    like( $template, qr/csrf-token\.inc/, 'refresh form retains CSRF protection' );
    like( $template, qr/cud-refresh-cache/, 'refresh action remains available' );
    unlike( $template, qr/name="(?:keyword|refine|available_only)"|nm2db-search-form/,
        'no plugin search form or refinement controls' );
    unlike( $template, qr/nm2db-results|FOREACH row IN results|<table/,
        'no plugin search results' );
    unlike( $template, qr/<script|datatables\.inc|api_search_url|api_suggestions_url/,
        'no plugin search JavaScript or DataTables assets' );
    done_testing;
};

subtest 'job refreshes the same caches as the CLI and records failures' => sub {
    my ( $status, $steps, $data, $installs, $released );
    my $locked = 1;
    my $fail = 0;
    my $dbh = bless {}, 'RefreshCacheTestDBH';
    $context->mock( dbh => sub { return $dbh } );
    my $db_mock = Test::MockModule->new( 'RefreshCacheTestDBH', no_auto => 1 );
    $db_mock->mock( selectrow_array => sub {
        if ( $_[1] =~ /GET_LOCK/ ) { return $locked }
        $released++;
        return 1;
    } );
    $plugin_mock->mock( new => sub { return bless {}, $plugin_class } );
    $plugin_mock->mock( install => sub { $installs++; die "Test refresh failure\n" if $fail; return 1 } );
    $job_mock->mock( start => sub { $status = 'started' } );
    $job_mock->mock( step => sub { $steps++ } );
    $job_mock->mock( discard_changes => sub { return $_[0] } );
    $job_mock->mock( status => sub { $status = $_[1] if @_ > 1; return @_ > 1 ? $_[0] : $status } );
    $job_mock->mock( store => sub { return $_[0] } );
    $job_mock->mock( finish => sub { $data = $_[1]; $status = 'finished' unless $status eq 'failed' } );

    local $SIG{__WARN__} = sub { };
    my $job = $job_class->new;
    $job->process;
    is( $installs, 1, 'calls the install/cache-refresh routine used by the script' );
    is( $steps, 1, 'one completed rebuild is one job step' );
    is( $status, 'finished', 'successful refresh finishes' );
    is_deeply( $data->{messages}, [], 'success has no errors' );
    like( $data->{report}->{elapsed_seconds}, qr/^\d+\.\d{3}$/, 'completion report contains elapsed time' );
    is( $released, 1, 'releases the refresh lock on success' );

    $fail = 1;
    $job->process;
    is( $status, 'failed', 'refresh failure marks the job failed' );
    like( $data->{messages}->[0]->{message}, qr/Test refresh failure/, 'failure is available in job details' );
    is( $released, 2, 'also releases the lock on failure' );

    $locked = 0;
    my $before = $installs;
    $job->process;
    is( $installs, $before, 'concurrent refresh does not touch caches' );
    is( $status, 'failed', 'concurrent refresh is rejected' );
    like( $data->{messages}->[0]->{message}, qr/Another.*running/, 'reports the active refresh' );
    is( $released, 2, 'does not release a lock owned by another connection' );
    done_testing;
};

done_testing;

package RefreshCacheTestTemplate;
sub param { my ( $self, %params ) = @_; @{$self}{keys %params} = values %params; }
sub output { return 'test template' }

package RefreshCacheTestDBH;
sub selectrow_array { die 'Must be mocked' }
