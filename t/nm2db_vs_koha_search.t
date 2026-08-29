#!/usr/bin/perl

use Modern::Perl;
use utf8;
use open ':std', ':encoding(UTF-8)';

use FindBin qw($Bin);
use lib "$Bin/..";

use Test::More;

BEGIN {
    plan skip_all => 'Set KOHA_CONF to run this integration test'
        unless $ENV{KOHA_CONF};
}

use C4::Context;
use Koha::Plugin::HKS3::NM2DBKeywordSearch;
use Koha::Plugin::HKS3::NM2DBKeywordSearch::OPACSearch ();
use Koha::SearchEngine::DBSearch::QueryBuilder;
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

my ($normalized_biblios) = $dbh->selectrow_array(q{
    SELECT COUNT(DISTINCT biblionumber)
    FROM nm2db_records
    WHERE type = 'biblio'
});
plan skip_all => 'No normalized bibliographic records found'
    unless $normalized_biblios;

my ($fulltext_index) = $dbh->selectrow_array(q{
    SELECT COUNT(*)
    FROM information_schema.statistics
    WHERE table_schema = DATABASE()
      AND table_name = 'nm2db_subfields'
      AND index_name = 'ft_subfield_value'
});
plan skip_all => 'NM2DB keyword fulltext index is not installed'
    unless $fulltext_index;

my $plugin = Koha::Plugin::HKS3::NM2DBKeywordSearch->new( { enable_plugins => 1 } );
plan skip_all => 'Could not instantiate NM2DB Keyword Search plugin'
    unless $plugin;

my @cases = (
    {
        name         => 'Perl keyword',
        plugin_query => 'perl',
        koha_query   => 'perl',
    },
    {
        name         => 'database keyword',
        plugin_query => 'database',
        koha_query   => 'database',
    },
    {
        name         => 'fiction keyword',
        plugin_query => 'fiction',
        koha_query   => 'fiction',
    },
    {
        name         => 'author keyword',
        plugin_query => 'conway',
        koha_query   => 'conway',
    },
    {
        name         => 'Flußperlmuschel keyword',
        plugin_query => 'Flußperlmuschel',
        koha_query   => 'Flußperlmuschel',
    },
    {
        name         => 'short exact title keyword',
        plugin_query => 'Blumen',
        koha_query   => 'Blumen',
    },
    {
        name         => 'exact title with stopwords and diacritic',
        plugin_query => 'Programme of the jornadas de taxonomía vegetal III',
        koha_query   => 'Programme of the jornadas de taxonomía vegetal III',
    },
    {
        name         => 'long exact title from typeahead',
        plugin_query => 'Brutzeitliche Einnischung des Weißrückenspechtes (Picoides leucotos) im Vergleich zum Buntspecht (Picoides major) in montanen Mischwäldern der nördlichen Kalkalpen',
        koha_query   => 'Brutzeitliche Einnischung des Weißrückenspechtes (Picoides leucotos) im Vergleich zum Buntspecht (Picoides major) in montanen Mischwäldern der nördlichen Kalkalpen',
    },
    {
        name         => 'two-word title phrase',
        plugin_query => 'Vogelwelt Wiens',
        koha_query   => 'Vogelwelt Wiens',
    },
    {
        name         => 'subject phrase',
        plugin_query => 'Science fiction',
        koha_query   => 'Science fiction',
    },
    {
        name         => 'technical title phrase',
        plugin_query => 'Computer programming',
        koha_query   => 'Computer programming',
    },
);

sub sorted_unique {
    my (@values) = @_;

    my %seen;
    return [ sort { $a <=> $b } grep { defined && !$seen{$_}++ } @values ];
}

sub is_subset {
    my ( $subset, $set ) = @_;

    my %set = map { $_ => 1 } @{$set};
    return !grep { !$set{$_} } @{$subset};
}

sub plugin_biblionumbers {
    my ( $query, $options ) = @_;

    my $rows = $plugin->search_records( $query, undef, undef, $options );
    return sorted_unique( map { $_->{biblionumber} } @{$rows} );
}

sub koha_biblionumbers {
    my ( $query, $limit ) = @_;

    my $result = Koha::Plugin::HKS3::NM2DBKeywordSearch::OPACSearch::search(
        search => $query,
        limit  => $limit,
    );

    return (
        $result->{raw_hits},
        sorted_unique( map { $_->{biblionumber} } @{ $result->{results} } )
    );
}

sub dbsearch_biblionumbers {
    my ( $query, $limits, $count, $offset ) = @_;

    $limits ||= [];
    return dbsearch_biblionumbers_from_dbquery(
        { query => $query, limits => $limits },
        $query, $count, $offset
    );
}

sub dbsearch_biblionumbers_from_dbquery {
    my ( $dbquery, $simple_query, $count, $offset ) = @_;

    $count  ||= 1000;
    $offset ||= 0;

    my $search = Koha::SearchEngine::DBSearch::Search->new( { index => 'biblios' } );
    my ( $error, $results ) = $search->search_compat(
        { dbsearch => $dbquery },
        $simple_query // ( $dbquery->{query} // q{} ), undef, undef, $count, $offset, undef, undef, undef, 0
    );

    my @records = $results ? grep { defined } @{ $results->{biblioserver}->{RECORDS} || [] } : ();
    return (
        $error,
        $results ? 0 + ( $results->{biblioserver}->{hits} // 0 ) : 0,
        sorted_unique( map { $search->extract_biblionumber($_) } @records )
    );
}

sub explain_difference {
    my ( $plugin_ids, $koha_ids ) = @_;

    my %plugin = map { $_ => 1 } @{$plugin_ids};
    my %koha   = map { $_ => 1 } @{$koha_ids};

    my @plugin_only = grep { !$koha{$_} } @{$plugin_ids};
    my @koha_only   = grep { !$plugin{$_} } @{$koha_ids};

    return (
        'plugin_only=' . join( ',', @plugin_only ),
        'koha_only=' . join( ',', @koha_only ),
    );
}

subtest 'plugin keyword search matches Koha keyword search' => sub {
    plan tests => 4 * @cases;

    for my $case (@cases) {
        my $plugin_ids = plugin_biblionumbers( $case->{plugin_query} );
        my ( $koha_hits, $koha_ids ) = koha_biblionumbers( $case->{koha_query}, 200 );

        ok( @{$plugin_ids}, "$case->{name}: plugin query returns records" );
        ok( @{$koha_ids},   "$case->{name}: Koha query returns records" );
        is(
            scalar @{$koha_ids}, $koha_hits,
            "$case->{name}: full Koha result set is inside comparison window"
        );
        is_deeply(
            $plugin_ids,
            $koha_ids,
            "$case->{name}: plugin and Koha return the same biblionumbers"
        ) or diag explain_difference( $plugin_ids, $koha_ids );
    }
};

subtest 'plugin result refinements narrow the hit set' => sub {
    plan tests => 5;

    my $title = 'Brutzeitliche Einnischung des Weißrückenspechtes (Picoides leucotos) im Vergleich zum Buntspecht (Picoides major) in montanen Mischwäldern der nördlichen Kalkalpen';
    my $title_ids = plugin_biblionumbers($title);
    my $refined_title_ids = plugin_biblionumbers( $title, { refine => 'Picoides' } );
    my $mismatched_title_ids = plugin_biblionumbers( $title, { refine => 'zzzxnonexistent' } );

    ok( @{$title_ids}, 'long title query returns records' );
    is_deeply(
        $refined_title_ids,
        $title_ids,
        'search-within-results keeps records matching the refinement term'
    );
    is_deeply(
        $mismatched_title_ids,
        [],
        'search-within-results removes records not matching the refinement term'
    );

    my $base_ids = plugin_biblionumbers('Blumen');
    my $available_ids = plugin_biblionumbers( 'Blumen', { available_only => 1 } );

    ok( @{$base_ids}, 'base query for availability refinement returns records' );
    ok( is_subset( $available_ids, $base_ids ), 'available-only records are a subset of the base result set' );
};

subtest 'DBSearch query CGI keeps facet limits separate' => sub {
    plan tests => 2;

    my $query_builder = Koha::SearchEngine::DBSearch::QueryBuilder->new( { index => 'biblios' } );
    my ( undef, undef, undef, $query_cgi, undef, undef, $limit_cgi ) =
        $query_builder->build_query_compat( [], ['nürnberg'], ['kw'], ['author:Müller, Philipp Ludwig Statius'] );

    is( $query_cgi, 'idx=kw&q=n%C3%BCrnberg', 'query CGI contains only the keyword search' );
    is(
        $limit_cgi,
        '&limit=author%3AM%C3%BCller%2C%20Philipp%20Ludwig%20Statius',
        'limit CGI keeps the leading separator expected by Koha facet templates'
    );
};

subtest 'DBSearch search-within limits refine result sets' => sub {
    plan tests => 4;

    my $search = Koha::SearchEngine::DBSearch::Search->new( { index => 'biblios' } );
    my $title = 'Brutzeitliche Einnischung des Weißrückenspechtes (Picoides leucotos) im Vergleich zum Buntspecht (Picoides major) in montanen Mischwäldern der nördlichen Kalkalpen';

    my ( $plain_error, $plain_results ) = $search->search_compat(
        { dbsearch => { query => $title, limits => ['Picoides'] } },
        $title, undef, undef, 20, 0, undef, undef, undef, 0
    );
    is( $plain_error, undef, 'plain search-within limit does not error' );
    is( $plain_results->{biblioserver}->{hits}, 1, 'plain search-within limit keeps matching records' );

    my ( $indexed_error, $indexed_results ) = $search->search_compat(
        { dbsearch => { query => $title, limits => ['kw:zzzxnonexistent'] } },
        $title, undef, undef, 20, 0, undef, undef, undef, 0
    );
    is( $indexed_error, undef, 'indexed search-within limit does not error' );
    is( $indexed_results->{biblioserver}->{hits}, 0, 'indexed search-within limit removes nonmatching records' );
};

subtest 'DBSearch derived publication-year limits filter result sets' => sub {
    my ($derived_table) = $dbh->selectrow_array(q{
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE table_schema = DATABASE()
          AND table_name = 'nm2db_keyword_search_derived_values'
    });
    plan skip_all => 'Derived index table is not installed'
        unless $derived_table;

    my ($derived_rows) = $dbh->selectrow_array(q{
        SELECT COUNT(*)
        FROM nm2db_keyword_search_derived_values
        WHERE name = 'date-of-publication'
    });
    plan skip_all => 'No derived publication-year values found'
        unless $derived_rows;

    my $base_ids = plugin_biblionumbers('Blumen');
    plan skip_all => 'Blumen test query has no base result set'
        unless @{$base_ids};

    my $placeholders = join q{,}, ('?') x @{$base_ids};
    my $year_rows = $dbh->selectall_arrayref(
        qq{
            SELECT numeric_value, COUNT(*) AS count
            FROM nm2db_keyword_search_derived_values
            WHERE name = 'date-of-publication'
              AND biblionumber IN ($placeholders)
            GROUP BY numeric_value
            ORDER BY count DESC, numeric_value
        },
        { Slice => {} },
        @{$base_ids}
    );
    plan skip_all => 'Blumen test query has no derived publication-year values'
        unless @{$year_rows};

    plan tests => 12;

    my $year = 0 + $year_rows->[0]->{numeric_value};
    my $expected_year_ids = $dbh->selectcol_arrayref(
        qq{
            SELECT DISTINCT biblionumber
            FROM nm2db_keyword_search_derived_values
            WHERE name = 'date-of-publication'
              AND numeric_value = ?
              AND biblionumber IN ($placeholders)
            ORDER BY biblionumber
        },
        undef,
        $year,
        @{$base_ids}
    );

    my ( $year_error, $year_hits, $year_ids ) =
        dbsearch_biblionumbers( 'Blumen', ["yr,st-numeric=$year"] );
    is( $year_error, undef, 'OPAC-style year limit does not error' );
    is( $year_hits, scalar @{$expected_year_ids}, 'OPAC-style year limit reports the filtered hit count' );
    is_deeply( $year_ids, sorted_unique( @{$expected_year_ids} ), 'OPAC-style year limit returns the expected records' );

    my ( $staff_year_error, $staff_year_hits, $staff_year_ids ) =
        dbsearch_biblionumbers( 'Blumen', ["yr,st-numeric:$year"] );
    is( $staff_year_error, undef, 'staff-style year limit does not error' );
    is( $staff_year_hits, $year_hits, 'staff-style year limit reports the same hit count' );
    is_deeply( $staff_year_ids, $year_ids, 'staff-style year limit returns the same records' );

    my ( $indexed_year_error, $indexed_year_hits, $indexed_year_ids ) =
        dbsearch_biblionumbers_from_dbquery(
        {
            query    => 'Blumen',
            operands => [ 'Blumen', $year ],
            indexes  => [ 'kw',     'yr,st-numeric' ],
            limits   => [],
        },
        'Blumen'
        );
    is( $indexed_year_error, undef, 'indexed publication-year operand does not error' );
    is( $indexed_year_hits,  $year_hits, 'indexed publication-year operand reports the same hit count' );
    is_deeply( $indexed_year_ids, $year_ids, 'indexed publication-year operand returns the same records' );

    my @years = sort { $a <=> $b } map { 0 + $_->{numeric_value} } @{$year_rows};
    my ( $from, $to ) = @years > 1 ? ( $years[0], $years[-1] ) : ( $year, $year );
    my $expected_range_ids = $dbh->selectcol_arrayref(
        qq{
            SELECT DISTINCT biblionumber
            FROM nm2db_keyword_search_derived_values
            WHERE name = 'date-of-publication'
              AND numeric_value BETWEEN ? AND ?
              AND biblionumber IN ($placeholders)
            ORDER BY biblionumber
        },
        undef,
        $from,
        $to,
        @{$base_ids}
    );
    my ( $range_error, $range_hits, $range_ids ) =
        dbsearch_biblionumbers( 'Blumen', ["yr,st-numeric=$from-$to"] );
    is( $range_error, undef, 'publication-year range limit does not error' );
    is( $range_hits, scalar @{$expected_range_ids}, 'publication-year range reports the filtered hit count' );
    is_deeply( $range_ids, sorted_unique( @{$expected_range_ids} ), 'publication-year range returns the expected records' );
};

subtest 'DBSearch can execute a derived publication-year search without keywords' => sub {
    my ($year) = $dbh->selectrow_array(q{
        SELECT numeric_value
        FROM nm2db_keyword_search_derived_values
        WHERE name = 'date-of-publication'
        GROUP BY numeric_value
        ORDER BY COUNT(*) DESC, numeric_value
        LIMIT 1
    });
    plan skip_all => 'No derived publication-year values found'
        unless $year;

    plan tests => 4;

    my ($expected_hits) = $dbh->selectrow_array(
        q{
            SELECT COUNT(DISTINCT biblionumber)
            FROM nm2db_keyword_search_derived_values
            WHERE name = 'date-of-publication'
              AND numeric_value = ?
        },
        undef,
        $year
    );
    my ( $error, $hits, $ids ) = dbsearch_biblionumbers( q{}, ["yr,st-numeric=$year"], 20 );

    is( $error, undef, 'year-only search does not error' );
    is( $hits, $expected_hits, 'year-only search reports all matching records' );
    ok( @{$ids}, 'year-only first page returns records' );

    my $wrong_year_count = @{$ids}
        ? $dbh->selectrow_array(
            'SELECT COUNT(*) FROM nm2db_keyword_search_derived_values WHERE name = ? AND biblionumber IN ('
                . join( q{,}, ('?') x @{$ids} )
                . ') AND numeric_value <> ?',
            undef,
            'date-of-publication',
            @{$ids},
            $year
        )
        : 0;
    is( $wrong_year_count, 0, 'year-only first page records all have the requested derived year' );
};

subtest 'DBSearch reports total hits beyond the intranet page size' => sub {
    plan tests => 7;

    my $search = Koha::SearchEngine::DBSearch::Search->new( { index => 'biblios' } );
    my ( $error, $results ) = $search->search_compat(
        { dbsearch => { query => 'Blumen', limits => [] } },
        'Blumen', undef, undef, 20, 0, undef, undef, undef, 0
    );

    is( $error, undef, 'first page search does not error' );
    cmp_ok( $results->{biblioserver}->{hits}, '>', 20, 'total hits are not capped to the first page' );
    is( scalar @{ $results->{biblioserver}->{RECORDS} }, 20, 'first page still contains one page of records' );

    my ( $page_error, $page_results ) = $search->search_compat(
        { dbsearch => { query => 'Blumen', limits => [] } },
        'Blumen', undef, undef, 20, 20, undef, undef, undef, 0
    );

    is( $page_error, undef, 'second page search does not error' );
    is(
        $page_results->{biblioserver}->{hits},
        $results->{biblioserver}->{hits},
        'second page keeps the same total hit count'
    );
    ok( defined $page_results->{biblioserver}->{RECORDS}->[20], 'second page first record is stored at the absolute offset' );
    my $defined_page_records = grep { defined $_ } @{ $page_results->{biblioserver}->{RECORDS} };
    is(
        $defined_page_records,
        20,
        'second page still contains one page of defined records'
    );
};

done_testing();
