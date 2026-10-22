#!/usr/bin/perl

use Modern::Perl;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More;
use Test::MockModule;
use Koha::Plugin::HKS3::NM2DBKeywordSearch;
use Koha::Plugin::HKS3::NM2DBKeywordSearch::Schema;

my $schema = 'Koha::Plugin::HKS3::NM2DBKeywordSearch::Schema';

subtest 'convert plugin tables once, preserving contents and core tables' => sub {
    my $dbh = CollationTestDBH->new;
    ok( $schema->upgrade($dbh), 'upgrade succeeds' );
    is( scalar @{ $dbh->{sql} }, 10, 'converts all nine plugin tables and the existing change queue' );
    is_deeply( [ values %{ $dbh->{collations} } ], [ ('utf8mb4_unicode_ci') x 10 ],
        'all plugin tables have one collation' );
    ok( !grep( /ALTER TABLE `(?!nm2db_)/, @{ $dbh->{sql} } ), 'never alters Koha core tables' );
    ok( !grep( /DROP|TRUNCATE|DELETE|INSERT/i, @{ $dbh->{sql} } ), 'conversion does not replace data' );
    is( $dbh->{RaiseError}, 0, 'restores the caller error setting' );
    ok( !$dbh->{locked}, 'releases the upgrade lock' );
    $dbh->{sql} = [];
    ok( $schema->upgrade($dbh), 'upgrade can be repeated' );
    is_deeply( $dbh->{sql}, [], 'already uniform schemas need no further DDL' );
    done_testing;
};

subtest 'explicit column collations and interrupted upgrades' => sub {
    my $dbh = CollationTestDBH->new;
    $dbh->{collations}{$_} = 'utf8mb4_unicode_ci' for keys %{ $dbh->{collations} };
    $dbh->{different_columns}{nm2db_fields} = 1;
    ok( $schema->upgrade($dbh), 'converts an old column despite a correct table default' );
    is( scalar @{ $dbh->{sql} }, 1, 'only the differing table is rebuilt' );
    like( $dbh->{sql}->[0], qr/ALTER TABLE `nm2db_fields`/, 'converts that table' );

    $dbh = CollationTestDBH->new;
    $dbh->{fail_on} = 'nm2db_fields';
    eval { $schema->upgrade($dbh) };
    like( $@, qr/Simulated DDL failure/, 'DDL failures propagate' );
    ok( !$dbh->{locked}, 'failure releases the lock' );
    is( $dbh->{RaiseError}, 0, 'failure restores error handling' );
    is( $dbh->{collations}{nm2db_records}, 'utf8mb4_unicode_ci', 'completed DDL remains completed' );
    $dbh->{sql} = [];
    delete $dbh->{fail_on};
    ok( $schema->upgrade($dbh), 'retry completes the remaining tables' );
    ok( !grep( /ALTER TABLE `nm2db_records`/, @{ $dbh->{sql} } ), 'retry skips completed conversions' );
    done_testing;
};

subtest 'preflight, concurrency and transaction guards' => sub {
    my $dbh = CollationTestDBH->new;
    delete $dbh->{collations}{nm2db_fields};
    eval { $schema->upgrade($dbh) };
    like( $@, qr/table nm2db_fields is missing/, 'missing Normalize dependency is reported' );
    is_deeply( $dbh->{sql}, [], 'preflight fails before converting any table' );
    ok( !$dbh->{locked}, 'preflight failure releases the lock' );

    $dbh = CollationTestDBH->new;
    delete $dbh->{collations}{nm2db_change_queue};
    ok( $schema->upgrade($dbh), 'an absent optional change queue is not created' );
    is( scalar @{ $dbh->{sql} }, 9, 'only installed plugin tables are converted' );

    $dbh = CollationTestDBH->new;
    $dbh->{locked} = 1;
    eval { $schema->upgrade($dbh) };
    like( $@, qr/another.*upgrade is running/i, 'concurrent conversion is refused' );
    is_deeply( $dbh->{sql}, [], 'a competing upgrade performs no DDL' );
    ok( $dbh->{locked}, 'does not release another connection lock' );
    $dbh->{AutoCommit} = 0;
    eval { $schema->upgrade($dbh) };
    like( $@, qr/requires its own transaction/, 'refuses implicit commits inside a caller transaction' );
    done_testing;
};

subtest 'install converts before cache queries; upgrade does not rebuild data' => sub {
    my $dbh = CollationTestDBH->new;
    my $context = Test::MockModule->new('C4::Context');
    $context->mock( dbh => sub { return $dbh } );
    my $plugin = bless {}, 'Koha::Plugin::HKS3::NM2DBKeywordSearch';
    my $mock = Test::MockModule->new('Koha::Plugin::HKS3::NM2DBKeywordSearch');
    my $words = Test::MockModule->new('Koha::Plugin::HKS3::NM2DBKeywordSearch::WordIndex');
    my $rebuilds = 0;
    $mock->mock( _ensure_index => sub { } );
    $mock->mock( configure_zebra_like_facet_settings => sub { } );
    $mock->mock( _refresh_keyword_lookup_tables => sub {
        ok( !grep( $_ ne 'utf8mb4_unicode_ci', values %{ $dbh->{collations} } ),
            'every collation is uniform before the first cache join' );
        $rebuilds++;
    } );
    $words->mock( refresh => sub { $rebuilds++ } );
    ok( $plugin->install, 'install succeeds with initially mixed/old tables' );
    is( $rebuilds, 2, 'install builds lookup caches and word index' );
    my @creates = grep { /CREATE TABLE/ } @{ $dbh->{sql} };
    is( scalar @creates, 6, 'all six search caches are created' );
    ok( !grep( !/COLLATE=utf8mb4_unicode_ci/, @creates ), 'fresh cache DDL consistently uses unicode_ci' );
    $dbh->{sql} = [];
    ok( $plugin->upgrade, 'Koha upgrade hook succeeds' );
    is( $rebuilds, 2, 'upgrade preserves existing caches instead of starting a full rebuild' );
    ok( !grep( /ALTER TABLE/, @{ $dbh->{sql} } ), 'repeat upgrade performs no conversion' );
    $dbh->{AutoCommit} = 0;
    $dbh->{sql} = [];
    eval { $plugin->upgrade };
    like( $@, qr/requires its own transaction/, 'upgrade rejects a caller transaction before cache creation' );
    is_deeply( $dbh->{sql}, [], 'no CREATE TABLE can implicitly commit the caller transaction' );
    done_testing;
};

done_testing;

package CollationTestDBH;

sub new {
    my @tables = qw(nm2db_records nm2db_fields nm2db_subfields nm2db_change_queue
        nm2db_keyword_search_weights nm2db_keyword_search_facets
        nm2db_keyword_search_facet_values nm2db_keyword_search_suggestions
        nm2db_keyword_search_derived_values nm2db_keyword_search_words);
    return bless { AutoCommit => 1, RaiseError => 0, sql => [], locked => 0,
        collations => { map { $_ => 'utf8mb4_general_ci' } @tables }, different_columns => {} }, shift;
}

sub quote_identifier { return '`' . $_[1] . '`' }

sub selectrow_array {
    my ( $self, $sql, undef, @params ) = @_;
    if ( $sql =~ /GET_LOCK/ ) {
        return 0 if $self->{locked};
        return $self->{locked} = 1;
    }
    if ( $sql =~ /RELEASE_LOCK/ ) { $self->{locked} = 0; return 1 }
    return $self->{collations}{ $params[0] } if $sql =~ /information_schema\.TABLES/;
    return $self->{different_columns}{ $params[0] } || 0 if $sql =~ /information_schema\.COLUMNS/;
    die "Unexpected query: $sql";
}

sub do {
    my ( $self, $sql ) = @_;
    if ( $sql =~ /ALTER TABLE `([^`]+)`/ ) {
        die "Simulated DDL failure\n" if ( $self->{fail_on} // q{} ) eq $1;
        $self->{collations}{$1} = 'utf8mb4_unicode_ci';
        $self->{different_columns}{$1} = 0;
    }
    push @{ $self->{sql} }, $sql;
    return 1;
}
