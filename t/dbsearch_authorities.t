#!/usr/bin/perl

use Modern::Perl;
use FindBin qw($Bin);
use lib "$Bin/..";

use Test::More;

BEGIN {
    plan skip_all => 'Set KOHA_CONF to run this integration test'
        unless $ENV{KOHA_CONF};
}

use C4::Context;
use Koha::Plugin::HKS3::NM2DBKeywordSearch;
use Koha::SearchEngine::DBSearch::Search;

my $dbh = C4::Context->dbh;

my ($nm2db_ready) = $dbh->selectrow_array(q{
    SELECT COUNT(*)
    FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND table_name IN ('nm2db_records', 'nm2db_fields', 'nm2db_subfields')
});
plan skip_all => 'Normalize MARC to DB tables are not installed'
    unless $nm2db_ready == 3;

my ($normalized_authorities) = $dbh->selectrow_array(q{
    SELECT COUNT(*)
    FROM nm2db_records
    WHERE type = 'authority'
});
plan skip_all => 'No normalized authority records found'
    unless $normalized_authorities;

my $plugin = Koha::Plugin::HKS3::NM2DBKeywordSearch->new( { enable_plugins => 1 } );
plan skip_all => 'Could not instantiate NM2DB Keyword Search plugin'
    unless $plugin;

my $search = Koha::SearchEngine::DBSearch::Search->new( { index => 'authorities' } );

sub authority_query {
    my (%args) = @_;

    return {
        marclist     => [ $args{marclist} // q{} ],
        and_or       => [ $args{and_or} // 'and' ],
        excluding    => [ $args{excluding} // q{} ],
        operator     => [ $args{operator} // 'contains' ],
        value        => [ $args{value} ],
        authtypecode => $args{authtypecode} // q{},
        orderby      => $args{orderby} // 'AuthidAsc',
    };
}

subtest 'short or stopword-only biblio queries return database matches' => sub {
    my ( $term, $expected );
    for my $candidate (qw(go who for)) {
        my $index_terms = $plugin->_opac_like_index_terms( $dbh, $candidate );
        next unless defined $index_terms && !@{$index_terms};

        my ($count) = Koha::Plugin::HKS3::NM2DBKeywordSearch::WordIndex->ready
            ? $dbh->selectrow_array(
                q{SELECT COUNT(DISTINCT r.biblionumber)
                    FROM nm2db_keyword_search_words w
                    JOIN nm2db_records r ON r.biblionumber = w.biblionumber AND r.type = 'biblio'
                    WHERE w.term LIKE ? ESCAPE '='}, undef, $candidate . '%'
            )
            : $dbh->selectrow_array(
            q{
                SELECT COUNT(DISTINCT r.biblionumber)
                FROM nm2db_records r
                JOIN nm2db_fields f
                    ON f.record_id = r.id
                JOIN nm2db_subfields s
                    ON s.field_id = f.id
                WHERE r.type = 'biblio'
                  AND s.value LIKE ? ESCAPE '='
            },
            undef,
            '%' . $candidate . '%'
        );
        next unless $count;
        ( $term, $expected ) = ( $candidate, $count );
        last;
    }

    plan skip_all => 'No short or stopword-only term has normalized biblio hits'
        unless defined $term;

    is( $plugin->count_records($term), $expected, "$term count agrees with the database hit set" );

    my $rows = $plugin->search_records( $term, undef, undef, { limit => 10 } );
    ok( @{$rows}, "$term returns result rows" );
    like( $rows->[0]->{value}, qr/\Q$term\E/i, 'result rows contain the fallback term' );

    my $facets = $plugin->search_facets($term);
    is( ref $facets, 'ARRAY', 'fallback query also returns a facet list' );
};

subtest 'authority searches use normalized MARC authority data' => sub {
    my $main_entry = $dbh->selectrow_hashref(q{
        SELECT r.authid, ah.authtypecode, at.auth_tag_to_report, s.value
        FROM nm2db_records r
        JOIN auth_header ah
            ON ah.authid = r.authid
        JOIN auth_types at
            ON at.authtypecode = ah.authtypecode
        JOIN nm2db_fields f
            ON f.record_id = r.id
           AND BINARY f.tag = BINARY at.auth_tag_to_report
        JOIN nm2db_subfields s
            ON s.field_id = f.id
           AND COALESCE(s.code, '') = 'a'
        WHERE r.type = 'authority'
          AND s.value IS NOT NULL
          AND TRIM(s.value) <> ''
        ORDER BY CHAR_LENGTH(s.value), r.authid
        LIMIT 1
    }, { Slice => {} });
    plan skip_all => 'No normalized authority main entry found'
        unless $main_entry;

    my ($expected_total) = $dbh->selectrow_array(q{
        SELECT COUNT(DISTINCT r.authid)
        FROM nm2db_records r
        JOIN auth_header ah
            ON ah.authid = r.authid
        JOIN auth_types at
            ON at.authtypecode = ah.authtypecode
        JOIN nm2db_fields f
            ON f.record_id = r.id
           AND BINARY f.tag = BINARY at.auth_tag_to_report
        JOIN nm2db_subfields s
            ON s.field_id = f.id
           AND COALESCE(s.code, '') = 'a'
        WHERE r.type = 'authority'
          AND ah.authtypecode = ?
          AND s.value = ?
    }, undef, $main_entry->{authtypecode}, $main_entry->{value} );

    my ( $results, $total ) = $search->search_auth_compat(
        authority_query(
            marclist     => 'mainmainentry',
            operator     => 'exact',
            value        => $main_entry->{value},
            authtypecode => $main_entry->{authtypecode},
        ),
        1, 50
    );
    is( $total, $expected_total, 'main authority query returns its normalized hit count' );
    ok(
        scalar( grep { $_->{authid} == $main_entry->{authid} } @{$results} ),
        'main authority query includes the expected authid'
    );
    ok(
        scalar( grep { $_->{summary} && $_->{authtype} } @{$results} ),
        'authority result has Koha summary metadata'
    );

    my ( $first_page, $first_total ) = $search->search_auth_compat(
        authority_query(
            marclist     => 'mainmainentry',
            operator     => 'exact',
            value        => $main_entry->{value},
            authtypecode => $main_entry->{authtypecode},
        ),
        1, 1
    );
    is( scalar @{$first_page}, 1, 'one-based first page does not skip the first authority' );
    ok( $first_page->[0]->{summary}, 'first result includes display metadata' );
    my ( $past_end, $past_end_total ) = $search->search_auth_compat(
        authority_query(
            marclist     => 'mainmainentry',
            operator     => 'exact',
            value        => $main_entry->{value},
            authtypecode => $main_entry->{authtypecode},
        ),
        $first_total + 1, 1
    );
    is( scalar @{$past_end}, 0, 'one-based offset after the last hit is empty' );
    is( $past_end_total, $first_total, 'pagination does not change the hit count' );

    my ( $compact_results, $compact_total ) = $search->search_auth_compat(
        authority_query(
            marclist     => 'mainmainentry',
            operator     => 'exact',
            value        => $main_entry->{value},
            authtypecode => $main_entry->{authtypecode},
        ),
        0, 50, 1
    );
    is( $compact_total, $expected_total, 'skipmetadata retains the authority hit count' );
    ok(
        !scalar( grep { scalar keys %{$_} != 1 || !exists $_->{authid} } @{$compact_results} ),
        'skipmetadata results only contain authid values'
    );

    my ( $all_results ) = $search->search_auth_compat(
        authority_query(
            operator => 'exact',
            value    => $main_entry->{value},
        ),
        0, 50, 1
    );
    ok(
        scalar( grep { $_->{authid} == $main_entry->{authid} } @{$all_results} ),
        'all-fields query includes the expected authid'
    );

    my $see_from = $dbh->selectrow_hashref(q{
        SELECT r.authid, s.value
        FROM nm2db_records r
        JOIN nm2db_fields f
            ON f.record_id = r.id
           AND f.tag REGEXP '^4[0-9]{2}$'
        JOIN nm2db_subfields s
            ON s.field_id = f.id
        WHERE r.type = 'authority'
          AND s.value IS NOT NULL
          AND TRIM(s.value) <> ''
        ORDER BY CHAR_LENGTH(s.value), r.authid
        LIMIT 1
    }, { Slice => {} });
    SKIP: {
        skip 'No normalized authority see-from field found', 1 unless $see_from;
        my ( $see_from_results ) = $search->search_auth_compat(
            authority_query(
                marclist => 'see-from',
                operator => 'exact',
                value    => $see_from->{value},
            ),
            0, 50, 1
        );
        ok(
            scalar( grep { $_->{authid} == $see_from->{authid} } @{$see_from_results} ),
            'see-from query includes the expected authid'
        );
    }

    my $heading_use = $dbh->selectrow_hashref(q{
        SELECT r.authid, SUBSTRING(s.value, 15, 1) AS value
        FROM nm2db_records r
        JOIN nm2db_fields f
            ON f.record_id = r.id
           AND f.tag = '008'
        JOIN nm2db_subfields s
            ON s.field_id = f.id
        WHERE r.type = 'authority'
          AND CHAR_LENGTH(s.value) >= 15
          AND SUBSTRING(s.value, 15, 1) <> ''
        ORDER BY r.authid
        LIMIT 1
    }, { Slice => {} });
    SKIP: {
        skip 'No normalized authority heading-use flag found', 1 unless $heading_use;
        my ( $heading_use_results ) = $search->search_auth_compat(
            authority_query(
                marclist => 'Heading-use-main-or-added-entry',
                operator => 'is',
                value    => $heading_use->{value},
            ),
            0, 50, 1
        );
        ok(
            scalar( grep { $_->{authid} == $heading_use->{authid} } @{$heading_use_results} ),
            'heading-use query includes the expected authid'
        );
    }

    my $thesaurus = $dbh->selectrow_hashref(q{
        SELECT
            r.authid,
            CASE SUBSTRING(s.value, 12, 1)
                WHEN 'a' THEN 'lcsh'
                WHEN 'b' THEN 'lcac'
                WHEN 'c' THEN 'mesh'
                WHEN 'd' THEN 'nal'
                WHEN 'k' THEN 'cash'
                WHEN 'n' THEN 'notapplicable'
                WHEN 'r' THEN 'aat'
                WHEN 's' THEN 'sears'
                WHEN 'v' THEN 'rvm'
            END AS value
        FROM nm2db_records r
        JOIN nm2db_fields f
            ON f.record_id = r.id
           AND f.tag = '008'
        JOIN nm2db_subfields s
            ON s.field_id = f.id
        WHERE r.type = 'authority'
          AND SUBSTRING(s.value, 12, 1) IN ('a', 'b', 'c', 'd', 'k', 'n', 'r', 's', 'v')
        ORDER BY r.authid
        LIMIT 1
    }, { Slice => {} });
    SKIP: {
        skip 'No normalized authority with a standard thesaurus code found', 1 unless $thesaurus;
        my ( $thesaurus_results ) = $search->search_auth_compat(
            authority_query(
                marclist => 'thesaurus',
                operator => 'is',
                value    => $thesaurus->{value},
            ),
            0, 50, 1
        );
        ok(
            scalar( grep { $_->{authid} == $thesaurus->{authid} } @{$thesaurus_results} ),
            'thesaurus query includes the expected authid'
        );
    }
};

done_testing;
