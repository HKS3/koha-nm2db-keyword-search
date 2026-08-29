package Koha::Plugin::HKS3::NM2DBKeywordSearch::OPACSearch;

use Modern::Perl;

use Exporter qw(import);
our @EXPORT_OK = qw(parse_search_string search);

use C4::Context;
use C4::Circulation qw(barcodedecode);
use C4::Languages qw(getlanguage);
use C4::Search qw(searchResults);
use Koha::ItemTypes;
use Koha::SearchEngine;
use Koha::SearchEngine::QueryBuilder;
use Koha::SearchEngine::Search;
use URI::Escape qw(uri_unescape);

my @MULTI_PARAM_NAMES = qw(op idx q limit nolimit sort_by server searchcat);
my %MULTI_PARAM = map { $_ => 1 } @MULTI_PARAM_NAMES;

sub parse_search_string {
    my ( $search_string, $default_limit ) = @_;

    $search_string //= q{};
    $default_limit ||= 20;

    my %params = map { $_ => [] } @MULTI_PARAM_NAMES;
    $params{count} = $default_limit;

    if ( $search_string =~ /^(?:idx|q|limit|sort_by|op|page|count|offset|server|nolimit|searchcat)=/ ) {
        for my $part ( split /[&;]/, $search_string ) {
            next unless length $part;

            my ( $key, $value ) = split /=/, $part, 2;
            $key   = uri_unescape($key);
            $value = defined $value ? uri_unescape($value) : q{};

            if ( $MULTI_PARAM{$key} ) {
                push @{ $params{$key} }, $value;
            } else {
                $params{$key} = $value;
            }
        }

        $params{count} ||= $default_limit;
    } elsif ( $search_string =~ s/^ccl:// ) {
        push @{ $params{q} }, $search_string;
    } elsif ( $search_string =~ /^[A-Za-z][\w-]*(?:,[\w-]+)*[=:]/ ) {
        push @{ $params{q} }, $search_string;
    } else {
        push @{ $params{idx} }, 'kw';
        push @{ $params{q} },   $search_string;
    }

    return \%params;
}

sub search {
    my (%args) = @_;

    my $search_string = $args{search};
    my $limit         = $args{limit} || 20;
    my $params        = $args{params} || parse_search_string( $search_string, $limit );
    my $interface     = $args{interface} || 'opac';

    die "Koha biblio search interface must be 'opac' or 'intranet'\n"
        unless $interface eq 'opac' || $interface eq 'intranet';

    C4::Context->interface($interface);
    C4::Context->set_userenv( undef, undef, undef, undef, undef, undef, undef, 0 )
        unless C4::Context->userenv;

    my $builder = Koha::SearchEngine::QueryBuilder->new(
        { index => $Koha::SearchEngine::BIBLIOS_INDEX }
    );
    my $searcher = Koha::SearchEngine::Search->new(
        { index => $Koha::SearchEngine::BIBLIOS_INDEX }
    );

    my @operators = @{ $params->{op} || [] };
    my @indexes   = @{ $params->{idx} || [] };
    my @operands  = @{ $params->{q} || [] };
    my @limits    = @{ $params->{limit} || [] };
    my @nolimits  = @{ $params->{nolimit} || [] };
    my @sort_by   = @{ $params->{sort_by} || [] };
    my @servers   = @{ $params->{server} || [] };
    @servers = ('biblioserver') unless @servers;

    @operators = map { uri_unescape($_) } @operators;
    @indexes   = map { uri_unescape($_) } @indexes;
    @operands  = map { uri_unescape($_) } @operands;
    @limits    = map { uri_unescape($_) } @limits;
    @nolimits  = map { uri_unescape($_) } @nolimits;

    my $default_sort_by = C4::Context->default_catalog_sort_by;
    $sort_by[0] = $default_sort_by if !$sort_by[0] && defined $default_sort_by;

    my %is_nolimit = map { $_ => 1 } @nolimits;
    @limits = grep { !$is_nolimit{$_} } @limits;

    if ( @{ $params->{searchcat} || [] } ) {
        my $itype_or_itemtype = C4::Context->preference('item-level_itypes') ? 'itype' : 'itemtype';
        for my $search_category ( @{ $params->{searchcat} } ) {
            my @itemtypes = Koha::ItemTypes->search( { searchcategory => $search_category } )->get_column('itemtype');
            push @limits, map { "mc-$itype_or_itemtype,phr:$_" } @itemtypes;
        }
    }

    if ( my $limit_yr = $params->{'limit-yr'} ) {
        push @limits, "yr,st-numeric=$limit_yr" if $limit_yr =~ /\d{4}/;
    }

    my $results_per_page = $params->{count} || $limit;
    my $offset           = $params->{offset} || 0;
    $offset = 0 if $offset < 0;
    my $page = $params->{page} || 1;
    $offset = ( $page - 1 ) * $results_per_page if $page > 1;

    my $scan          = $params->{scan};
    my $basic_search  = $operands[0] && !$operands[1] ? 1 : 0;
    my $whole_record  = $params->{whole_record} || 0;
    my $weight_search = exists $params->{weight_search_submitted}
        ? ( $params->{weight_search} ? 1 : 0 )
        : 1;
    my $lang = $params->{language} || getlanguage();

    if ( $interface eq 'intranet' ) {
        for ( my $i = 0 ; $i < @operands ; $i++ ) {
            $operands[$i] = barcodedecode( $operands[$i] )
                if defined $indexes[$i] && $indexes[$i] eq 'bc';
        }
    }

    my $suppress = $interface eq 'opac' ? _opac_suppression_applies() : 0;
    my $built = _build_query(
        builder                 => $builder,
        interface               => $interface,
        operators               => \@operators,
        operands                => \@operands,
        indexes                 => \@indexes,
        limits                  => \@limits,
        sort_by                 => \@sort_by,
        lang                    => $lang,
        scan                    => $scan,
        suppress                => $suppress,
        whole_record            => $whole_record,
        weight_search           => $weight_search,
        weight_search_submitted => $params->{weight_search_submitted},
    );

    my $search = _run_search(
        searcher         => $searcher,
        built            => $built,
        interface        => $interface,
        sort_by          => \@sort_by,
        servers          => \@servers,
        results_per_page => $results_per_page,
        offset           => $offset,
        scan             => $scan,
    );

    if ( ( $search->{hits} || 0 ) == 0 && $basic_search ) {
        my @quoted_operands = @operands;
        $quoted_operands[0] = '"' . $quoted_operands[0] . '"';

        my $quoted_built = _build_query(
            builder                 => $builder,
            interface               => $interface,
            operators               => \@operators,
            operands                => \@quoted_operands,
            indexes                 => \@indexes,
            limits                  => \@limits,
            sort_by                 => \@sort_by,
            lang                    => $lang,
            scan                    => $scan,
            suppress                => $suppress,
            whole_record            => $whole_record,
            weight_search           => $weight_search,
            weight_search_submitted => $params->{weight_search_submitted},
        );

        my $quoted_search = _run_search(
            searcher         => $searcher,
            built            => $quoted_built,
            interface        => $interface,
            sort_by          => \@sort_by,
            servers          => \@servers,
            results_per_page => $results_per_page,
            offset           => $offset,
            scan             => $scan,
        );

        if ( $quoted_search->{hits} ) {
            $built  = $quoted_built;
            $search = $quoted_search;
        }
    }

    my $records = $search->{records} || [];
    my @search_results_args = (
        { interface => $interface },
        $built->{query_desc},
        $search->{hits} || 0,
        $results_per_page,
        $offset,
        $scan,
        $records
    );
    push @search_results_args, { anonymous_session => 1 } if $interface eq 'opac';
    my @results = searchResults(@search_results_args);

    my @rows = map {
        {
            biblionumber  => 0 + ( $_->{biblionumber} || 0 ),
            title         => $_->{title}  || q{},
            author        => $_->{author} || q{},
            result_number => $_->{result_number},
        }
    } grep { $_->{biblionumber} } @results;

    return {
        hits             => @rows ? ( $search->{hits} || 0 ) : 0,
        raw_hits         => $search->{hits} || 0,
        results_per_page => $results_per_page,
        offset           => $offset,
        query            => $built->{query},
        simple_query     => $built->{simple_query},
        query_type       => $built->{query_type},
        query_desc       => $built->{query_desc},
        results          => \@rows,
    };
}

sub _build_query {
    my (%args) = @_;

    my %options = (
        weighted_fields         => $args{weight_search},
        weight_search_submitted => $args{weight_search_submitted},
    );
    if ( $args{interface} eq 'opac' ) {
        $options{suppress} = $args{suppress};
        $options{is_opac}  = 1;
    } else {
        $options{whole_record} = $args{whole_record};
    }

    my ( $error, $query, $simple_query, $query_cgi, $query_desc, $limit, $limit_cgi, $limit_desc, $query_type ) =
        $args{builder}->build_query_compat(
        $args{operators},
        $args{operands},
        $args{indexes},
        $args{limits},
        $args{sort_by},
        $args{interface} eq 'opac' ? 0 : $args{scan},
        $args{lang},
        \%options
        );

    die "Koha $args{interface} query build failed: $error\n" if $error;

    return {
        query       => $query,
        simple_query => $simple_query,
        query_cgi   => $query_cgi,
        query_desc  => $query_desc,
        limit       => $limit,
        limit_cgi   => $limit_cgi,
        limit_desc  => $limit_desc,
        query_type  => $query_type,
    };
}

sub _run_search {
    my (%args) = @_;

    my $itemtypes_nocategory =
        { map { $_->{itemtype} => $_ } @{ Koha::ItemTypes->search_with_localization->unblessed } };

    my ( $error, $results_hashref, $facets );
    my $eval_error;
    {
        local $@;
        eval {
            my @search_args = (
                $args{built}->{query},
                $args{built}->{simple_query},
                $args{sort_by},
                $args{servers},
                $args{results_per_page},
                $args{offset},
                undef,
                $itemtypes_nocategory,
                $args{built}->{query_type},
                $args{scan}
            );
            push @search_args, 1 if $args{interface} eq 'opac';
            ( $error, $results_hashref, $facets ) = $args{searcher}->search_compat(@search_args);
        };
        $eval_error = $@;
    }

    die "Koha $args{interface} search failed: $error$eval_error\n"
        if $error || $eval_error;

    my $server = 'biblioserver';
    return {
        hits    => $results_hashref->{$server}->{hits} || 0,
        records => $results_hashref->{$server}->{RECORDS} || [],
        facets  => $facets,
    };
}

sub _opac_suppression_applies {
    return 0 unless C4::Context->preference('OpacSuppression');

    if ( C4::Context->preference('OpacSuppressionByIPRange') ) {
        my $ip_address = $ENV{REMOTE_ADDR} // q{};
        my $ip_range   = C4::Context->preference('OpacSuppressionByIPRange');
        return $ip_address !~ /^$ip_range/ ? 1 : 0;
    }

    return 1;
}

1;
