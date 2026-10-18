#!/usr/bin/perl

use Modern::Perl;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More;
use Test::MockModule;
use MARC::Record;
use MARC::Field;

BEGIN {
    plan skip_all => 'Set KOHA_CONF to run this integration test' unless $ENV{KOHA_CONF};
}
use C4::Context;
use Koha::Plugin::HKS3::NM2DBKeywordSearch;
use Koha::Plugin::HKS3::NM2DBKeywordSearch::WordIndex;

my $index = 'Koha::Plugin::HKS3::NM2DBKeywordSearch::WordIndex';
is_deeply( $index->tokens('Go go, Doctor Who; Chicago'), [qw(go doctor who chicago)],
    'tokenization includes short words and stopwords and removes duplicates' );
is_deeply( $index->tokens('Äpfel Weißrückenspecht'), [qw(äpfel weißrückenspecht)],
    'tokenization preserves Unicode letters' );

SKIP: {
    skip 'Build the word index first', 2 unless $index->ready;
    my $dbh = C4::Context->dbh;
    my ($id) = $dbh->selectrow_array(q{SELECT biblionumber FROM nm2db_records WHERE type = 'biblio' ORDER BY id LIMIT 1});
    skip 'No normalized biblio record available', 2 unless $id;

    subtest 'short terms, word prefixes and cache updates' => sub {
        $dbh->begin_work;
        eval {
            my $record = MARC::Record->new;
            $record->append_fields( MARC::Field->new( '245', ' ', ' ', a => 'Go Doctor Who Chicago' ) );
            $index->update_record( $id, $record );
            for my $query ( ['go'], ['who'], [ 'go', 'who' ] ) {
                my $hits = $index->search($query);
                ok( scalar( grep { $_->{biblionumber} == $id } @{$hits} ),
                    join( ' ', @{$query} ) . ' finds the fixture, including standalone short words' );
            }
            $record = MARC::Record->new;
            $record->append_fields( MARC::Field->new( '245', ' ', ' ', a => 'Chicago Darwin' ) );
            $index->update_record( $id, $record );
            ok( !scalar( grep { $_->{biblionumber} == $id } @{ $index->search(['go']) } ),
                'go does not match inside Chicago, and old words are removed on update' );
            ok( scalar( grep { $_->{biblionumber} == $id } @{ $index->search(['darw']) } ),
                'prefix matches an updated word' );
            $dbh->rollback;
            1;
        } or do { my $error = $@; $dbh->rollback; die $error };
    };

    subtest 'count, pages and facets reuse a request-local hit set' => sub {
        my $calls = 0;
        my $original = $index->can('search');
        my $mock = Test::MockModule->new($index);
        $mock->mock( search => sub { $calls++; $original->(@_) } );
        my $plugin = bless {}, 'Koha::Plugin::HKS3::NM2DBKeywordSearch';
        my $count = $plugin->count_records('go');
        ok( $count > 0, 'go has indexed hits' );
        my $rows = $plugin->search_records( 'go', undef, undef, { limit => 2, include_xml => 1 } );
        is( scalar @{$rows}, 2, 'only the requested page is returned' );
        ok( $rows->[0]->{xml}, 'page has MARCXML for Koha display' );
        $plugin->search_facets('go');
        is( $calls, 1, 'matching is performed once, not once per count/page/facet query' );
        $plugin->search_records( 'go', undef, undef, { limit => 2, offset => 2 } );
        is( $calls, 1, 'another page on the same request reuses matching' );
        $plugin->count_records('darwin');
        is( $calls, 2, 'a different query gets a fresh hit set' );
        $plugin->count_records( 'go', undef, undef, { refine => 'who' } );
        is( $calls, 4, 'refinement has its own indexed intersection' );
        my $fresh = bless {}, 'Koha::Plugin::HKS3::NM2DBKeywordSearch';
        $fresh->count_records('go');
        is( $calls, 5, 'a new request does not reuse stale hits' );
    };
}
done_testing;
