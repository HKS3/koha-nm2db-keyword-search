#!/usr/bin/perl

use Modern::Perl;
use open ':std', ':encoding(UTF-8)';

use Encode qw(decode);
use Getopt::Long qw(GetOptions);
use HTML::Entities qw(decode_entities);
use HTTP::Tiny;
use Pod::Usage qw(pod2usage);
use URI::Escape qw(uri_escape_utf8 uri_unescape);

my $base_url = $ENV{NM2DB_BASE_URL};
my $limit = 200;
my $format = 'text';
my $interface = 'opac';
my $intranet_user = $ENV{KOHA_INTRANET_USER} || 'koha';
my $intranet_password = $ENV{KOHA_INTRANET_PASSWORD} || 'koha4test';
my $help;
my %http_cookies;

GetOptions(
    'base-url=s'          => \$base_url,
    'limit=i'             => \$limit,
    'format=s'            => \$format,
    'interface=s'         => \$interface,
    'intranet-user=s'     => \$intranet_user,
    'intranet-password=s' => \$intranet_password,
    'help|h'              => \$help,
) or pod2usage(2);

pod2usage(0) if $help;
pod2usage( -msg => 'Missing search string', -exitval => 2 ) unless @ARGV;

die "--limit must be greater than zero\n" unless $limit > 0;
die "--format must be text, tsv, or ids\n"
    unless $format eq 'text' || $format eq 'tsv' || $format eq 'ids';
die "--interface must be opac or intranet\n"
    unless $interface eq 'opac' || $interface eq 'intranet';

$base_url ||= $interface eq 'intranet' ? 'http://127.0.0.1:8081' : 'http://127.0.0.1:8080';
$base_url =~ s{/\z}{};

my $query = join ' ', map { decode( 'UTF-8', $_ ) } @ARGV;
intranet_login() if $interface eq 'intranet';

my $url = koha_web_search_url( $query, $limit, $interface );
my $response = http_get($url);
my $results = parse_koha_web_results( $response->{content}, $interface );

if ( $format eq 'ids' ) {
    say join ',', map { $_->{biblionumber} } @{$results};
    exit 0;
}

if ( $format eq 'tsv' ) {
    say join "\t", qw(biblionumber title url);
    for my $result ( @{$results} ) {
        say join "\t", $result->{biblionumber}, $result->{title}, detail_url( $result->{biblionumber} );
    }
    exit 0;
}

say "Koha " . ( $interface eq 'opac' ? 'OPAC' : 'intranet' ) . " web search URL: $url";
say "Parsed results: " . scalar @{$results};
for my $result ( @{$results} ) {
    printf "%8d  %s\n", $result->{biblionumber}, $result->{title};
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
    my %seen;
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
        my $biblionumber = 0 + $1;
        next if $seen{$biblionumber}++;
        push @results, {
            biblionumber => $biblionumber,
            title        => clean_html_text($2),
        };
    }

    return [ sort { $a->{biblionumber} <=> $b->{biblionumber} } @results ];
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

    my $response = HTTP::Tiny->new( timeout => 60 )->get(
        $url,
        {
            headers => {
                Accept => 'text/html',
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

    my $response = HTTP::Tiny->new( timeout => 60 )->post_form(
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

sub detail_url {
    my ($biblionumber) = @_;

    my $path = $interface eq 'intranet'
        ? '/cgi-bin/koha/catalogue/detail.pl'
        : '/cgi-bin/koha/opac-detail.pl';

    return build_url( "$base_url$path", biblionumber => $biblionumber );
}

__END__

=head1 NAME

koha_web_search.pl - run a search through Koha's OPAC or intranet web search route

=head1 SYNOPSIS

  koha_web_search.pl [--base-url http://127.0.0.1:8080] [--limit 200] book
  koha_web_search.pl --interface intranet [--base-url http://127.0.0.1:8081] book
  koha_web_search.pl --format tsv kw=perl
  koha_web_search.pl --format ids 'idx=kw&q=perl'

=head1 DESCRIPTION

This script fetches Koha's OPAC C</cgi-bin/koha/opac-search.pl> or staff
C</cgi-bin/koha/catalogue/search.pl> over HTTP and parses biblionumbers from
the rendered results page. In intranet mode it logs in first using
C<--intranet-user>/C<--intranet-password> or the C<KOHA_INTRANET_USER> and
C<KOHA_INTRANET_PASSWORD> environment variables.

Accepted search strings:

=over

=item * plain terms, e.g. C<perl>, sent as C<idx=kw&q=perl>

=item * CCL, e.g. C<kw=perl> or C<ccl:kw=perl>

=item * URL parameters, e.g. C<idx=kw&q=perl>

=back

=cut
