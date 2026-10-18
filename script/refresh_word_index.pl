#!/usr/bin/perl

use Modern::Perl;
use FindBin qw($Bin);
use lib "$Bin/..";
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);
use Koha::Plugin::HKS3::NM2DBKeywordSearch::WordIndex;

my $confirm;
GetOptions( 'confirm' => \$confirm ) or die "Usage: $0 --confirm\n";
die "Set KOHA_CONF and pass --confirm to create/replace the derived word index\n"
    unless $ENV{KOHA_CONF} && $confirm;
$| = 1;
my $started = time;
my $records = Koha::Plugin::HKS3::NM2DBKeywordSearch::WordIndex->refresh(
    sub { say "Indexed $_[0] records" if $_[0] % 10000 == 0 }
);
printf "Word index: %d records in %.3fs\n", $records, time - $started;
