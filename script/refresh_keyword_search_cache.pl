#!/usr/bin/perl

use Modern::Perl;
use Time::HiRes qw(time);

use FindBin qw($Bin);
use lib "$Bin/..";

BEGIN {
    die "Set KOHA_CONF to run this script inside a Koha environment\n"
        unless $ENV{KOHA_CONF};
}

use Koha::Plugins::Base;
use Koha::Plugin::HKS3::NM2DBKeywordSearch;

my $started = time;
my $plugin = Koha::Plugin::HKS3::NM2DBKeywordSearch->new( { enable_plugins => 1 } )
    or die "Could not instantiate NM2DB Keyword Search plugin\n";

$plugin->install;

printf "NM2DB keyword search cache refreshed in %.3fs\n", time - $started;
