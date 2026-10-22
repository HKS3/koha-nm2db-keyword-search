package Koha::Plugin::HKS3::NM2DBKeywordSearch::Schema;

use Modern::Perl;

my @TABLES = qw(
    nm2db_records nm2db_fields nm2db_subfields
    nm2db_keyword_search_weights nm2db_keyword_search_facets
    nm2db_keyword_search_facet_values nm2db_keyword_search_suggestions
    nm2db_keyword_search_derived_values nm2db_keyword_search_words
);

sub upgrade {
    my ( $class, $dbh ) = @_;

    die "NM2DB schema conversion requires its own transaction\n" unless $dbh->{AutoCommit};
    local $dbh->{RaiseError} = 1;
    my ($locked) = $dbh->selectrow_array(
        q{SELECT GET_LOCK(CONCAT('nm2db_keyword_schema:', MD5(DATABASE())), 0)}
    );
    die "Another NM2DB keyword schema upgrade is running\n" unless $locked;

    my $success = eval {
        # Only the explicitly named plugin tables, never Koha core tables.
        my @tables = @TABLES;
        push @tables, 'nm2db_change_queue' if $class->_table_collation( $dbh, 'nm2db_change_queue' );
        $class->_convert_tables( $dbh, \@tables );
        1;
    };
    my $error = $@;
    my $released = eval {
        $dbh->selectrow_array(q{SELECT RELEASE_LOCK(CONCAT('nm2db_keyword_schema:', MD5(DATABASE())))});
        1;
    };
    die $error unless $success;
    die $@ unless $released;

    return 1;
}

sub _table_collation {
    my ( $class, $dbh, $table ) = @_;
    return $dbh->selectrow_array(
        q{SELECT TABLE_COLLATION FROM information_schema.TABLES
          WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND TABLE_TYPE = 'BASE TABLE'},
        undef, $table
    );
}

sub _convert_tables {
    my ( $class, $dbh, $tables ) = @_;

    # Preflight before any DDL; a missing NormalizeMARC2DB dependency is an error.
    my %collations;
    for my $table ( @{$tables} ) {
        $collations{$table} = $class->_table_collation( $dbh, $table )
            or die "Cannot upgrade NM2DB Keyword Search: table $table is missing\n";
    }

    my $converted = 0;
    for my $table ( @{$tables} ) {
        my ($different_columns) = $dbh->selectrow_array(
            q{SELECT COUNT(*) FROM information_schema.COLUMNS
              WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
                AND COLLATION_NAME IS NOT NULL AND COLLATION_NAME <> 'utf8mb4_unicode_ci'},
            undef, $table
        );
        next if $collations{$table} eq 'utf8mb4_unicode_ci' && !$different_columns;
        # DDL is not transactional. Completed tables are skipped on a retry.
        $dbh->do( 'ALTER TABLE ' . $dbh->quote_identifier($table)
                . ' CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci' );
        $converted++;
    }
    return $converted;
}

1;
