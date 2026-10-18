package Koha::Plugin::HKS3::NM2DBKeywordSearch::Jobs::RefreshCache;

use Modern::Perl;
use base 'Koha::BackgroundJob';

use C4::Context;
use Time::HiRes qw(time);
use Try::Tiny;

sub job_type {
    return 'plugin_nm2db_keyword_search_refresh_cache';
}

sub enqueue {
    my ($self) = @_;

    return $self->SUPER::enqueue(
        {
            job_size  => 1,
            job_args  => {},
            job_queue => 'long_tasks',
        }
    );
}

sub process {
    my ($self) = @_;

    $self->start;
    my $started = time;
    my $dbh = C4::Context->dbh;
    my $locked;
    my @messages;

    try {
        ($locked) = $dbh->selectrow_array(
            q{SELECT GET_LOCK(CONCAT('nm2db_cache_refresh:', SHA1(DATABASE())), 0)}
        );
        die "Another NM2DB search cache refresh job is running\n" unless $locked;

        # Use the same routine as script/refresh_keyword_search_cache.pl.
        require Koha::Plugin::HKS3::NM2DBKeywordSearch;
        my $plugin = Koha::Plugin::HKS3::NM2DBKeywordSearch->new( { enable_plugins => 1 } )
            or die "Could not instantiate NM2DB Keyword Search plugin\n";
        $plugin->install;
        $self->discard_changes;
        $self->step if $self->status eq 'started';
    } catch {
        warn "NM2DB search cache refresh failed: $_";
        push @messages, { message => "$_" };
        $self->status('failed')->store;
    };

    $dbh->selectrow_array(
        q{SELECT RELEASE_LOCK(CONCAT('nm2db_cache_refresh:', SHA1(DATABASE())))}
    ) if $locked;
    $self->finish(
        {
            messages => \@messages,
            report   => { elapsed_seconds => sprintf( '%.3f', time - $started ) },
        }
    );
}

1;
