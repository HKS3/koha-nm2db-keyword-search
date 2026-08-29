#!/usr/bin/perl

use Modern::Perl;
use open ':std', ':encoding(UTF-8)';

use FindBin qw($Bin);
use lib "$Bin/..";

use Encode qw(decode);
use Getopt::Long qw(GetOptions);
use Pod::Usage qw(pod2usage);

BEGIN {
    die "Set KOHA_CONF to run this script inside a Koha environment\n"
        unless $ENV{KOHA_CONF};
}

use Koha::Plugin::HKS3::NM2DBKeywordSearch::OPACSearch qw(search);

my $limit  = 200;
my $format = 'text';
my $interface = 'opac';
my $help;

GetOptions(
    'limit=i'     => \$limit,
    'format=s'    => \$format,
    'interface=s' => \$interface,
    'help|h'      => \$help,
) or pod2usage(2);

pod2usage(0) if $help;
pod2usage( -msg => 'Missing search string', -exitval => 2 ) unless @ARGV;

die "--limit must be greater than zero\n" unless $limit > 0;
die "--format must be text, tsv, or ids\n"
    unless $format eq 'text' || $format eq 'tsv' || $format eq 'ids';
die "--interface must be opac or intranet\n"
    unless $interface eq 'opac' || $interface eq 'intranet';

my $query = join ' ', map { decode( 'UTF-8', $_ ) } @ARGV;
my $result = search(
    search    => $query,
    limit     => $limit,
    interface => $interface,
);

if ( $format eq 'ids' ) {
    say join ',', map { $_->{biblionumber} } @{ $result->{results} };
    exit 0;
}

if ( $format eq 'tsv' ) {
    say join "\t", qw(result_number biblionumber title author);
    for my $row ( @{ $result->{results} } ) {
        say join "\t",
            $row->{result_number} || q{},
            $row->{biblionumber},
            $row->{title},
            $row->{author};
    }
    exit 0;
}

say "Koha " . ( $interface eq 'opac' ? 'OPAC' : 'intranet' ) . " code search";
say "Raw hits: " . $result->{raw_hits};
say "Displayed rows: " . scalar @{ $result->{results} };
say "Query type: " . ( $result->{query_type} || 'ccl' );
say "Built query: " . ( $result->{query} // q{} );
for my $row ( @{ $result->{results} } ) {
    printf "%4s %8d  %s%s\n",
        $row->{result_number} || q{},
        $row->{biblionumber},
        $row->{title},
        $row->{author} ? ' / ' . $row->{author} : q{};
}

__END__

=head1 NAME

koha_opac_code_search.pl - run Koha OPAC search code without HTTP

=head1 SYNOPSIS

  koha_opac_code_search.pl [--limit 200] book
  koha_opac_code_search.pl --interface intranet book
  koha_opac_code_search.pl --format tsv kw=perl
  koha_opac_code_search.pl --format ids 'idx=kw&q=perl'

=head1 DESCRIPTION

This script reproduces the catalog-search part of Koha's OPAC
C</cgi-bin/koha/opac-search.pl> or staff
C</cgi-bin/koha/catalogue/search.pl> in-process. It builds the query with
C<Koha::SearchEngine::QueryBuilder>, runs C<search_compat>, applies the same
basic-search quoted retry, and formats records through C<C4::Search::searchResults>.

It does not fetch the OPAC page and does not parse rendered HTML.

Accepted search strings:

=over

=item * plain terms, e.g. C<perl>, sent as C<idx=kw&q=perl>

=item * CCL, e.g. C<kw=perl> or C<ccl:kw=perl>

=item * URL parameters, e.g. C<idx=kw&q=perl>

=back

=cut
