#!/usr/bin/perl

use Modern::Perl;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More;
use Test::MockModule;
use Koha::Plugin::HKS3::NM2DBKeywordSearch;

# Do not run the plugin constructor: these hooks need no installation or DB.
my $plugin = bless {}, 'Koha::Plugin::HKS3::NM2DBKeywordSearch';
my $context = Test::MockModule->new('C4::Context');
$context->mock( dbh => sub { die 'Unexpected database access in typeahead hook test' } );

for my $engine ( 'DBSearch', 'Zebra', 'Elasticsearch', undef, 'DBSearch' ) {
    $context->mock( preference => sub {
        die 'Unexpected preference' unless $_[1] eq 'SearchEngine';
        return $engine;
    } );
    my $label = $engine // 'unset';
    for my $hook ( qw(opac_js intranet_js) ) {
        my $js = $plugin->$hook;
        if ( defined $engine && $engine eq 'DBSearch' ) {
            like( $js, qr/nm2dbCatalogueTypeaheadLoaded/, "$hook enabled for $label" );
        } else {
            is( $js, q{}, "$hook disabled for $label" );
        }
    }
    is(
        $plugin->suggestions_url,
        '/api/v1/contrib/nm2db_keyword_search/suggestions',
        "standalone suggestions URL unchanged for $label"
    );
}

done_testing;
