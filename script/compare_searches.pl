#!/usr/bin/perl

use Modern::Perl;
use open ':std', ':encoding(UTF-8)';

use FindBin qw($Bin);
use lib "$Bin/..";

use Getopt::Long qw(GetOptions);
use HTML::Entities qw(decode_entities);
use HTTP::Tiny;
use JSON::PP qw(decode_json);
use Pod::Usage qw(pod2usage);
use URI::Escape qw(uri_escape_utf8 uri_unescape);

BEGIN {
    die "Set KOHA_CONF to run this script inside a Koha environment\n"
        unless $ENV{KOHA_CONF};
}

use C4::Biblio qw(GetMarcFromKohaField);
use C4::Context;
use C4::Search qw(SimpleSearch new_record_from_zebra);
use Koha::Plugin::HKS3::NM2DBKeywordSearch;
use Koha::Plugin::HKS3::NM2DBKeywordSearch::OPACSearch ();

my $limit = 200;
my $base_url = $ENV{NM2DB_BASE_URL};
my $koha_mode = 'web';
my $plugin_mode = 'api';
my $intranet_user = $ENV{KOHA_INTRANET_USER} || 'koha';
my $intranet_password = $ENV{KOHA_INTRANET_PASSWORD} || 'koha4test';
my $brief;
my $help;
my %http_cookies;

GetOptions(
    'limit=i'            => \$limit,
    'base-url=s'         => \$base_url,
    'koha-mode=s'        => \$koha_mode,
    'plugin-mode=s'      => \$plugin_mode,
    'intranet-user=s'    => \$intranet_user,
    'intranet-password=s' => \$intranet_password,
    'brief'              => \$brief,
    'help|h'             => \$help,
) or pod2usage(2);

pod2usage(0) if $help;

my $search_file = shift @ARGV
    or pod2usage( -msg => 'Missing search file', -exitval => 2 );

die "--limit must be greater than zero\n" unless $limit > 0;
die "--koha-mode must be 'web', 'opac-code', 'intranet-web', 'intranet-code', or 'direct'\n"
    unless $koha_mode eq 'web'
    || $koha_mode eq 'opac-code'
    || $koha_mode eq 'intranet-web'
    || $koha_mode eq 'intranet-code'
    || $koha_mode eq 'direct';
die "--plugin-mode must be 'api' or 'direct'\n"
    unless $plugin_mode eq 'api' || $plugin_mode eq 'direct';

$base_url ||= $koha_mode =~ /^intranet-/ ? 'http://127.0.0.1:8081' : 'http://127.0.0.1:8080';
$base_url =~ s{/\z}{};
my $koha_interface = $koha_mode =~ /^intranet-/ ? 'intranet' : 'opac';
my $needs_intranet_http = $koha_mode eq 'intranet-web'
    || ( $plugin_mode eq 'api' && $koha_interface eq 'intranet' );

my $dbh = C4::Context->dbh;
assert_nm2db_ready($dbh);

my $plugin = Koha::Plugin::HKS3::NM2DBKeywordSearch->new( { enable_plugins => 1 } )
    or die "Could not instantiate NM2DB Keyword Search plugin\n";

my @cases = read_search_file($search_file);
die "No searches found in $search_file\n" unless @cases;

intranet_login() if $needs_intranet_http;

my $failed = 0;
my $index  = 0;
my $ok_count = 0;
my $diff_count = 0;
my $total_plugin_only = 0;
my $total_koha_only = 0;
for my $case (@cases) {
    $index++;

    my $plugin_ids = plugin_biblionumbers( $case->{plugin_query}, $plugin_mode );
    my ( $koha_hits, $koha_ids, $koha_url ) = koha_biblionumbers( $case->{koha_query}, $limit, $koha_mode );
    my ( $plugin_only, $koha_only ) = diff_ids( $plugin_ids, $koha_ids );

    my $truncated = ( $koha_mode eq 'direct' || $koha_mode eq 'opac-code' || $koha_mode eq 'intranet-code' )
        && $koha_hits > $limit;
    my $matches   = !@{$plugin_only} && !@{$koha_only} && !$truncated;

    if ($matches) {
        $ok_count++;
        printf "OK   %3d %-32s plugin=%d koha=%d\n",
            $index, printable_label($case), scalar @{$plugin_ids}, $koha_hits;
        next;
    }

    $failed = 1;
    $diff_count++;
    $total_plugin_only += scalar @{$plugin_only};
    $total_koha_only   += scalar @{$koha_only};
    printf "DIFF %3d %-32s plugin=%d koha=%d",
        $index, printable_label($case), scalar @{$plugin_ids}, $koha_hits;
    print " compared_koha=" . scalar @{$koha_ids} if $truncated;
    printf " plugin_only=%d koha_only=%d", scalar @{$plugin_only}, scalar @{$koha_only}
        if $brief;
    print "\n";
    next if $brief;

    printf "      plugin query: %s\n", $case->{plugin_query};
    printf "      Koha query:   %s\n", $case->{koha_query};
    printf "      Koha URL:     %s\n", $koha_url if $koha_url;
    print  "      warning: Koha hits exceed --limit; increase --limit for a complete comparison\n"
        if $truncated;
    print_diff_list( 'plugin only', $plugin_only );
    print_diff_list( 'Koha only',   $koha_only );
}

printf "SUMMARY total=%d ok=%d diff=%d plugin_only=%d koha_only=%d\n",
    $index, $ok_count, $diff_count, $total_plugin_only, $total_koha_only;

exit $failed;

sub assert_nm2db_ready {
    my ($dbh) = @_;

    my ($nm2db_ready) = $dbh->selectrow_array(q{
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE table_schema = DATABASE()
          AND table_name IN ('nm2db_records', 'nm2db_fields', 'nm2db_subfields')
    });
    die "Normalize MARC to DB tables are not installed\n" unless $nm2db_ready == 3;

    my ($normalized_biblios) = $dbh->selectrow_array(q{
        SELECT COUNT(DISTINCT biblionumber)
        FROM nm2db_records
        WHERE type = 'biblio'
    });
    die "No normalized bibliographic records found\n" unless $normalized_biblios;

    my ($fulltext_index) = $dbh->selectrow_array(q{
        SELECT COUNT(*)
        FROM information_schema.statistics
        WHERE table_schema = DATABASE()
          AND table_name = 'nm2db_subfields'
          AND index_name = 'ft_subfield_value'
    });
    die "NM2DB keyword fulltext index is not installed\n" unless $fulltext_index;
}

sub read_search_file {
    my ($file) = @_;

    open my $fh, '<', $file or die "Cannot open $file: $!\n";

    my @cases;
    my $line_number = 0;
    while ( my $line = <$fh> ) {
        $line_number++;
        chomp $line;
        $line =~ s/\r\z//;
        $line =~ s/^\s+|\s+\z//g;
        next if $line eq q{} || $line =~ /^#/;

        my @columns = map { trim($_) } split /\t/, $line, -1;
        die "Too many tab-separated columns in $file line $line_number\n"
            if @columns > 3;

        my $case;
        if ( @columns == 1 ) {
            $case = {
                line         => $line_number,
                label        => $columns[0],
                plugin_query => $columns[0],
                koha_query   => $columns[0],
            };
        } elsif ( @columns == 2 ) {
            $case = {
                line         => $line_number,
                label        => $columns[0],
                plugin_query => $columns[0],
                koha_query   => $columns[1],
            };
        } else {
            $case = {
                line         => $line_number,
                label        => $columns[0],
                plugin_query => $columns[1],
                koha_query   => $columns[2],
            };
        }

        die "Empty plugin query in $file line $line_number\n"
            unless length $case->{plugin_query};
        die "Empty Koha query in $file line $line_number\n"
            unless length $case->{koha_query};

        push @cases, $case;
    }

    close $fh;
    return @cases;
}

sub trim {
    my ($value) = @_;
    $value //= q{};
    $value =~ s/^\s+|\s+\z//g;
    return $value;
}

sub biblionumber_from_zebra_record {
    my ($raw_record) = @_;

    my $record = new_record_from_zebra( 'biblioserver', $raw_record );
    return unless $record;

    my ( $tag, $subfield ) = GetMarcFromKohaField('biblio.biblionumber');
    if ( $tag < 10 ) {
        my $field = $record->field($tag);
        return $field ? $field->data : undef;
    }

    return $record->subfield( $tag, $subfield );
}

sub sorted_unique {
    my (@values) = @_;

    my %seen;
    return [ sort { $a <=> $b } grep { defined && !$seen{$_}++ } @values ];
}

sub plugin_biblionumbers {
    my ( $query, $mode ) = @_;

    return plugin_api_biblionumbers($query) if $mode eq 'api';

    my $rows = $plugin->search_records($query);
    return sorted_unique( map { $_->{biblionumber} } @{$rows} );
}

sub plugin_api_biblionumbers {
    my ($query) = @_;

    my $url = build_url(
        "$base_url/api/v1/contrib/nm2db_keyword_search/search",
        keyword => $query,
        type    => $koha_interface,
    );
    my $response = http_get($url);
    my $payload = decode_json( $response->{content} );
    my $rows = $payload->{results} || [];

    return sorted_unique( map { $_->{biblionumber} } @{$rows} );
}

sub koha_biblionumbers {
    my ( $query, $limit, $mode ) = @_;

    return koha_web_biblionumbers( $query, $limit, 'opac' ) if $mode eq 'web';
    return koha_web_biblionumbers( $query, $limit, 'intranet' ) if $mode eq 'intranet-web';
    return koha_code_biblionumbers( $query, $limit, 'opac' ) if $mode eq 'opac-code';
    return koha_code_biblionumbers( $query, $limit, 'intranet' ) if $mode eq 'intranet-code';

    my ( $error, $records, $hits ) = SimpleSearch( $query, 0, $limit );
    die "Koha SimpleSearch failed for '$query': $error\n" if defined $error;

    return (
        $hits,
        sorted_unique(
            map { biblionumber_from_zebra_record($_) }
                @{$records}
        )
    );
}

sub koha_code_biblionumbers {
    my ( $query, $limit, $interface ) = @_;

    my $result = Koha::Plugin::HKS3::NM2DBKeywordSearch::OPACSearch::search(
        search    => $query,
        limit     => $limit,
        interface => $interface,
    );

    return (
        $result->{raw_hits},
        sorted_unique( map { $_->{biblionumber} } @{ $result->{results} } )
    );
}

sub koha_web_biblionumbers {
    my ( $query, $limit, $interface ) = @_;

    my $url = koha_web_search_url( $query, $limit, $interface );
    my $response = http_get($url);
    my $ids = sorted_unique(
        map { $_->{biblionumber} } @{ parse_koha_web_results( $response->{content}, $interface ) }
    );

    return ( scalar @{$ids}, $ids, $url );
}

sub koha_web_search_url {
    my ( $query, $limit, $interface ) = @_;

    my @params;

    if ( $query =~ /^(?:idx|q|limit|sort_by|op|page|count)=/ ) {
        my $has_count;
        for my $part ( split /[&;]/, $query ) {
            next unless length $part;
            my ( $key, $value ) = split /=/, $part, 2;
            $key = uri_unescape($key);
            $value = defined $value ? uri_unescape($value) : q{};
            $has_count = 1 if $key eq 'count';
            push @params, $key, $value;
        }
        push @params, count => $limit unless $has_count;
    } elsif ( $query =~ s/^ccl:// ) {
        @params = ( count => $limit, q => $query );
    } elsif ( $query =~ /^[A-Za-z][\w-]*(?:,[\w-]+)*[=:]/ ) {
        @params = ( count => $limit, q => $query );
    } else {
        @params = ( count => $limit, idx => 'kw', q => $query );
    }

    my $path = $interface eq 'intranet'
        ? '/cgi-bin/koha/catalogue/search.pl'
        : '/cgi-bin/koha/opac-search.pl';

    return build_url( "$base_url$path", @params );
}

sub parse_koha_web_results {
    my ( $html, $interface ) = @_;

    my @results;
    my $detail_path = $interface eq 'intranet'
        ? 'catalogue/detail.pl'
        : 'opac-detail.pl';
    while (
        $html =~ m{
            <a\b
            (?=[^>]*\bclass="[^"]*\btitle\b)
            (?=[^>]*\bhref="[^"]*\Q$detail_path\E\?[^"]*biblionumber=(\d+)[^"]*")
            [^>]*>
            (.*?)
            </a>
        }sigx
        )
    {
        push @results, {
            biblionumber => 0 + $1,
            title        => clean_html_text($2),
        };
    }

    return \@results;
}

sub clean_html_text {
    my ($html) = @_;

    $html //= q{};
    $html =~ s/<[^>]+>/ /g;
    $html = decode_entities($html);
    $html =~ s/\s+/ /g;
    $html =~ s/^\s+|\s+\z//g;

    return $html;
}

sub http_get {
    my ($url) = @_;

    my $ua = HTTP::Tiny->new( timeout => 60 );
    my $response = $ua->get(
        $url,
        {
            headers => {
                Accept => 'text/html,application/json',
                ( %http_cookies ? ( Cookie => cookie_header() ) : () ),
            },
        }
    );
    store_cookies($response);

    die "HTTP GET failed for $url: $response->{status} $response->{reason}\n"
        unless $response->{success};

    return $response;
}

sub http_post_form {
    my ( $url, $form ) = @_;

    my $ua = HTTP::Tiny->new( timeout => 60 );
    my $response = $ua->post_form(
        $url,
        $form,
        {
            headers => {
                Accept => 'text/html',
                ( %http_cookies ? ( Cookie => cookie_header() ) : () ),
            },
        }
    );
    store_cookies($response);

    die "HTTP POST failed for $url: $response->{status} $response->{reason}\n"
        unless $response->{success};

    return $response;
}

sub intranet_login {
    my $login_url = "$base_url/cgi-bin/koha/mainpage.pl";
    my $login_page = http_get($login_url);
    my ($csrf_token) = $login_page->{content} =~ /name="csrf_token"\s+value="([^"]+)"/;
    die "Could not find intranet login CSRF token at $login_url\n" unless $csrf_token;

    my $response = http_post_form(
        $login_url,
        {
            login_userid       => $intranet_user,
            login_password     => $intranet_password,
            koha_login_context => 'intranet',
            login_op           => 'cud-login',
            csrf_token         => $csrf_token,
        }
    );

    die "Intranet login failed for $intranet_user at $login_url\n"
        if $response->{content} =~ /\bloginform\b/;
}

sub store_cookies {
    my ($response) = @_;

    my $set_cookie = $response->{headers}->{'set-cookie'} // return;
    my @headers = ref $set_cookie eq 'ARRAY' ? @{$set_cookie} : ($set_cookie);
    for my $header (@headers) {
        my ($pair) = split /;/, $header, 2;
        my ( $name, $value ) = split /=/, $pair, 2;
        next unless defined $name && defined $value && length $name;
        $name =~ s/^\s+|\s+\z//g;
        $http_cookies{$name} = $value;
    }
}

sub cookie_header {
    return join '; ', map { "$_=$http_cookies{$_}" } sort keys %http_cookies;
}

sub build_url {
    my ( $base, @params ) = @_;

    my @pairs;
    while (@params) {
        my $key = shift @params;
        my $value = shift @params;
        push @pairs, uri_escape_utf8($key) . '=' . uri_escape_utf8( $value // q{} );
    }

    return $base . ( @pairs ? '?' . join( '&', @pairs ) : q{} );
}

sub diff_ids {
    my ( $plugin_ids, $koha_ids ) = @_;

    my %plugin = map { $_ => 1 } @{$plugin_ids};
    my %koha   = map { $_ => 1 } @{$koha_ids};

    return (
        [ grep { !$koha{$_} } @{$plugin_ids} ],
        [ grep { !$plugin{$_} } @{$koha_ids} ],
    );
}

sub print_diff_list {
    my ( $label, $ids ) = @_;

    if ( !@{$ids} ) {
        print "      $label: none\n";
        return;
    }

    print "      $label:\n";
    my $titles = titles_for_biblionumbers($ids);
    for my $id ( @{$ids} ) {
        printf "        %s%s\n", $id, $titles->{$id} ? '  ' . $titles->{$id} : q{};
    }
}

sub titles_for_biblionumbers {
    my ($ids) = @_;

    return {} unless @{$ids};

    my $placeholders = join ',', ('?') x @{$ids};
    my $rows = $dbh->selectall_arrayref(
        "SELECT biblionumber, title, author FROM biblio WHERE biblionumber IN ($placeholders)",
        { Slice => {} },
        @{$ids}
    );

    my %titles;
    for my $row ( @{$rows} ) {
        my $title = $row->{title} // q{};
        my $author = $row->{author} // q{};
        $titles{ $row->{biblionumber} } =
            $author ? "$title / $author" : $title;
    }

    return \%titles;
}

sub printable_label {
    my ($case) = @_;

    my $label = $case->{label};
    $label = substr( $label, 0, 29 ) . '...' if length $label > 32;
    return $label;
}

__END__

=head1 NAME

compare_searches.pl - compare NM2DB keyword search results with Koha search

=head1 SYNOPSIS

  compare_searches.pl [--base-url http://127.0.0.1:8080] [--limit 200] searches.tsv
  compare_searches.pl --koha-mode opac-code searches.tsv
  compare_searches.pl --koha-mode intranet-code searches.tsv
  compare_searches.pl --koha-mode intranet-web searches.tsv
  compare_searches.pl --koha-mode direct --plugin-mode direct searches.tsv

=head1 OPTIONS

=over

=item B<--base-url>

Base URL for HTTP searches. Defaults to C<http://127.0.0.1:8080> for OPAC
web searches and C<http://127.0.0.1:8081> for intranet web searches.

=item B<--koha-mode>

C<web> uses C</cgi-bin/koha/opac-search.pl> over HTTP and parses rendered OPAC
results. C<intranet-web> logs into the staff client and parses
C</cgi-bin/koha/catalogue/search.pl>. C<opac-code> and C<intranet-code> call
the matching query builder, C<search_compat>, quoted fallback, and result
formatting in-process without HTTP. C<direct> uses C<C4::Search::SimpleSearch>.
Defaults to C<web>.

=item B<--plugin-mode>

C<api> uses the plugin's C</api/v1/contrib/nm2db_keyword_search/search> route
over HTTP. C<direct> calls the plugin Perl API in-process. Defaults to C<api>.

=item B<--limit>

Number of Koha results requested from the web route, code path, or direct
C<SimpleSearch> result limit.

=item B<--intranet-user>, B<--intranet-password>

Credentials used by C<intranet-web>, or by plugin API comparisons using the
intranet HTTP route. Defaults to C<KOHA_INTRANET_USER> and
C<KOHA_INTRANET_PASSWORD>, falling back to the KTD defaults C<koha> and
C<koha4test>.

=item B<--brief>

For differing searches, print only result counts and difference counts instead
of listing every differing biblionumber.

=back

=head1 SEARCH FILE

Blank lines and lines beginning with C<#> are ignored.

One tab-separated column:

  perl

Runs the plugin query C<perl> and the Koha query C<perl>. In web mode this is
sent to OPAC search as C<idx=kw&q=perl>.

Two tab-separated columns:

  perl    kw=perl

Runs the first column as the plugin query and the second column as the Koha
query.

Three tab-separated columns:

  Perl keyword    perl    kw=perl

Uses the first column as the display label.

=cut
