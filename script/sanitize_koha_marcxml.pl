#!/usr/bin/env perl

use strict;
use warnings;
use Encode qw(decode);
use Getopt::Long qw(GetOptions);

my $repair_mojibake = 1;
my $drop_952f       = 1;
my $help            = 0;

GetOptions(
    'repair-mojibake!' => \$repair_mojibake,
    'drop-952f!'       => \$drop_952f,
    'help'             => \$help,
) or usage();

usage() if $help || @ARGV != 2;

my ( $input, $output ) = @ARGV;

open my $in, '<:encoding(UTF-8)', $input
    or die "Cannot open $input: $!\n";
open my $out, '>:encoding(UTF-8)', $output
    or die "Cannot write $output: $!\n";

my %branch_canon = (
    GEo   => 'GEO',
    MIn   => 'MIN',
    ZOOHb => 'ZOOHB',
);

my %stats = (
    lines                   => 0,
    records                 => 0,
    item_fields             => 0,
    repaired_lines          => 0,
    dropped_itemnumbers     => 0,
    dropped_duplicate_a     => 0,
    dropped_duplicate_b     => 0,
    dropped_duplicate_y     => 0,
    dropped_952f            => 0,
    dropped_long_952f       => 0,
);

my $in_952 = 0;
my %seen_952;

while ( my $line = <$in> ) {
    ++$stats{lines};
    ++$stats{records} if $line =~ /<record(?:\s|>)/;

    if ($repair_mojibake) {
        my $fixed = repair_utf8_mojibake($line);
        if ( $fixed ne $line ) {
            $line = $fixed;
            ++$stats{repaired_lines};
        }
    }

    if ( $line =~ /<datafield\b[^>]*\btag="952"/ ) {
        $in_952 = 1;
        %seen_952 = ();
        ++$stats{item_fields};
    }

    if ($in_952 && $line =~ /<subfield code="9">/) {
        ++$stats{dropped_itemnumbers};
        next;
    }

    if ($in_952 && $line =~ /^(\s*)<subfield code="([A-Za-z0-9])">(.*?)<\/subfield>(\s*)$/) {
        my ( $indent, $code, $value, $trail ) = ( $1, $2, $3, $4 );
        $value = trim($value);

        if ( $code =~ /^[aby]$/ ) {
            if ( $seen_952{$code}++ ) {
                ++$stats{"dropped_duplicate_$code"};
                next;
            }

            if ( $code eq 'a' || $code eq 'b' ) {
                $value =~ s/\s*\|.*\z//;
                $value = trim($value);
                $value = uc $value;
                $value = $branch_canon{$value} // $value;
            }
            elsif ( $code eq 'y' ) {
                $value = uc $value;
            }
        }
        elsif ( $code eq 'f' && $drop_952f ) {
            ++$stats{dropped_952f};
            next;
        }
        elsif ( $code eq 'f' ) {
            if ( length($value) > 10 ) {
                ++$stats{dropped_long_952f};
                next;
            }
        }

        print {$out} $indent, '<subfield code="', $code, '">', $value, '</subfield>', $trail, "\n";
        next;
    }

    print {$out} $line;

    if ($in_952 && $line =~ /<\/datafield>/) {
        $in_952 = 0;
        %seen_952 = ();
    }
}

close $in  or die "Cannot close $input: $!\n";
close $out or die "Cannot close $output: $!\n";

print join(
    "\n",
    map { "$_=$stats{$_}" }
        qw(
        lines records item_fields repaired_lines dropped_itemnumbers
        dropped_duplicate_a dropped_duplicate_b dropped_duplicate_y
        dropped_952f dropped_long_952f
        )
), "\n";

sub trim {
    my ($value) = @_;
    $value =~ s/\A\s+//;
    $value =~ s/\s+\z//;
    return $value;
}

sub repair_utf8_mojibake {
    my ($text) = @_;

    # Repair localized UTF-8 bytes that were decoded as Latin-1/Windows-1252
    # and then encoded as UTF-8 again, e.g. FluÃ -> Fluß.
    $text =~ s{
        ([\x{00C2}-\x{00DF}][\x{0080}-\x{00BF}])
    }{
        decode_mojibake_bytes($1)
    }gex;

    $text =~ s{
        ([\x{00E0}-\x{00EF}][\x{0080}-\x{00BF}]{2})
    }{
        decode_mojibake_bytes($1)
    }gex;

    $text =~ s{
        ([\x{00F0}-\x{00F4}][\x{0080}-\x{00BF}]{3})
    }{
        decode_mojibake_bytes($1)
    }gex;

    return $text;
}

sub decode_mojibake_bytes {
    my ($chars) = @_;
    my $bytes = pack 'C*', map { ord $_ } split //, $chars;
    return eval { decode( 'UTF-8', $bytes, Encode::FB_CROAK ) } // $chars;
}

sub usage {
    die <<"USAGE";
Usage: $0 [--no-repair-mojibake] [--no-drop-952f] INPUT.xml OUTPUT.xml

Sanitizes Koha MARCXML for bulkmarcimport:
  - repairs localized UTF-8 mojibake such as FluÃperlmuschel
  - removes incoming 952\$9 itemnumbers so Koha assigns new itemnumbers
  - keeps only the first 952\$a, 952\$b, and 952\$y per item
  - normalizes branch and itemtype codes
  - drops 952\$f by default because it maps to Koha's short optional
    items.coded_location_qualifier column
USAGE
}
