#!/usr/bin/perl

use Modern::Perl;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More;

BEGIN { plan skip_all => 'Set KOHA_CONF for the collation integration test' unless $ENV{KOHA_CONF} }
use C4::Context;
use Koha::Plugin::HKS3::NM2DBKeywordSearch::Schema;

my $dbh = C4::Context->dbh;
local $dbh->{RaiseError} = 1;
local $dbh->{PrintError} = 0;
my $schema = 'Koha::Plugin::HKS3::NM2DBKeywordSearch::Schema';
my $prefix = 'nm2db_collation_test_' . $$ . '_' . time;
my @tables = map { $prefix . '_' . $_ } qw(general unicode mixed);
my @created;

my $success = eval {
    for my $i ( 0 .. $#tables ) {
        my $table = $dbh->quote_identifier( $tables[$i] );
        my $collation = $i == 0 ? 'utf8mb4_general_ci' : 'utf8mb4_unicode_ci';
        my $value_collation = $i == 2 ? ' COLLATE utf8mb4_general_ci' : q{};
        $dbh->do("CREATE TABLE $table (id INT PRIMARY KEY, tag CHAR(6), value VARCHAR(64)$value_collation,
            KEY tag_idx (tag)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=$collation");
        push @created, $tables[$i];
        $dbh->do("INSERT INTO $table (id,tag,value) VALUES (1,'245',?),(2,'100',?)",
            undef, 'Größe 😀', 'Äpfel und Weißrückenspecht');
    }
    my ( $general, $unicode ) = map { $dbh->quote_identifier($_) } @tables[0, 1];
    eval { $dbh->selectrow_array("SELECT COUNT(*) FROM $general g JOIN $unicode u ON u.tag=g.tag") };
    like( $@, qr/Illegal mix of collations/, 'reproduces issue #2 before conversion' );
    my @before = map {
        $dbh->selectall_arrayref( 'SELECT id,tag,value FROM ' . $dbh->quote_identifier($_) . ' ORDER BY id' )
    } @tables;
    is( $schema->_convert_tables( $dbh, \@tables ), 2, 'converts legacy default and explicit legacy column' );
    is( $dbh->selectrow_array("SELECT COUNT(*) FROM $general g JOIN $unicode u ON u.tag=g.tag"),
        2, 'plain equality joins work after conversion without COLLATE/BINARY workarounds' );
    for my $i ( 0 .. $#tables ) {
        is_deeply( $dbh->selectall_arrayref(
            'SELECT id,tag,value FROM ' . $dbh->quote_identifier( $tables[$i] ) . ' ORDER BY id' ),
            $before[$i], 'conversion preserves row IDs and Unicode/emoji content: ' . $i );
        is( $schema->_table_collation( $dbh, $tables[$i] ), 'utf8mb4_unicode_ci', 'uniform table default: ' . $i );
        is( $dbh->selectrow_array(q{SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=?
              AND COLLATION_NAME IS NOT NULL AND COLLATION_NAME<>'utf8mb4_unicode_ci'}, undef, $tables[$i]),
            0, 'uniform character columns: ' . $i );
    }
    is( $schema->_convert_tables( $dbh, \@tables ), 0, 'completed conversion is idempotent' );
    1;
};
my $error = $@;
# Only tables created by this test are removed; catalog tables are never changed.
$dbh->do( 'DROP TABLE ' . $dbh->quote_identifier($_) ) for reverse @created;
die $error unless $success;
done_testing;
