package Koha::SearchEngine::DBSearch::Search;

use Modern::Perl;

use base qw(Class::Accessor);

use C4::Context;
use MARC::Record;
use Koha::SearchEngine;
use Koha::SearchEngine::Search;
use Koha::Plugin::HKS3::NM2DBKeywordSearch;

sub new {
    my ( $class, $params ) = @_;

    return bless { index => $params->{index} }, $class;
}

sub index {
    my ($self) = @_;

    return $self->{index};
}

sub search_compat {
    my (
        $self,       $query,            $simple_query, $sort_by,
        $servers,    $results_per_page, $offset,       $branches,
        $item_types, $query_type,       $scan
    ) = @_;

    return $self->_zebra_searcher->search_compat(
        $query,       $simple_query, $sort_by,
        $servers,     $results_per_page, $offset,
        $branches,    $item_types,   $query_type,
        $scan
    )
        if $self->index && $self->index ne $Koha::SearchEngine::BIBLIOS_INDEX;

    return ( 'DBSearch does not support scan searches yet', undef, undef )
        if $scan;

    $offset //= 0;
    $offset = 0 if $offset < 0;
    $results_per_page ||= 20;

    my $plugin = Koha::Plugin::HKS3::NM2DBKeywordSearch->new( { enable_plugins => 1 } );
    my ( $facet_name, $facet_value, $filter_options ) = $self->_filters_from_query($query);
    my $keyword = $self->_keyword_from_query( $query, $simple_query );
    return ( 'No query entered', undef, undef )
        unless $keyword =~ /\S/ || $self->_has_filter_query( $facet_name, $facet_value, $filter_options );

    my $hits = $plugin->count_records( $keyword, $facet_name, $facet_value, $filter_options );
    my $rows = $plugin->search_records(
        $keyword,
        $facet_name,
        $facet_value,
        {
            %{$filter_options},
            include_xml => 1,
            limit       => $results_per_page,
            offset      => $offset,
        }
    );

    my @records;
    for my $i ( 0 .. $#{$rows} ) {
        $records[ $offset + $i ] = $rows->[$i]->{xml};
    }

    my $facets = $self->_convert_facets(
        $plugin->search_facets( $keyword, $facet_name, $facet_value, $filter_options )
    );
    if ( C4::Context->interface eq 'opac' ) {
        my $rules = C4::Context->yaml_preference('OpacHiddenItems');
        $facets = Koha::SearchEngine::Search->post_filter_opac_facets( { facets => $facets, rules => $rules } );
    }

    return (
        undef,
        {
            biblioserver => {
                hits    => $hits,
                RECORDS => \@records,
            }
        },
        $facets
    );
}

sub simple_search_compat {
    my ( $self, $query, $offset, $max_results ) = @_;

    return $self->_zebra_searcher->simple_search_compat( $query, $offset, $max_results )
        if $self->index && $self->index ne $Koha::SearchEngine::BIBLIOS_INDEX;

    return ( 'No query entered', undef, undef ) unless $query;

    $offset //= 0;
    $offset = 0 if $offset < 0;
    $max_results ||= 20;

    my $keyword = $self->_keyword_from_query( $query, $query );
    my $plugin = Koha::Plugin::HKS3::NM2DBKeywordSearch->new( { enable_plugins => 1 } );
    my ( $facet_name, $facet_value, $filter_options ) = $self->_filters_from_query($query);
    my $hits = $plugin->count_records( $keyword, $facet_name, $facet_value, $filter_options );
    my $rows = $plugin->search_records(
        $keyword,
        $facet_name,
        $facet_value,
        {
            %{$filter_options},
            include_xml => 1,
            limit       => $max_results,
            offset      => $offset,
        }
    );

    my @records = map { $_->{xml} } @{$rows};

    return ( undef, \@records, $hits );
}

sub extract_biblionumber {
    my ( $self, $searchresultrecord ) = @_;

    my $record = ref $searchresultrecord eq 'MARC::Record'
        ? $searchresultrecord
        : MARC::Record->new_from_xml( $searchresultrecord, 'UTF-8' );

    return Koha::SearchEngine::Search::extract_biblionumber($record);
}

sub search_auth_compat {
    my $self = shift;

    return $self->_zebra_searcher->search_auth_compat(@_);
}

sub max_result_window { undef }

sub _keyword_from_query {
    my ( $self, $query, $simple_query ) = @_;

    my $keyword;
    if ( ref $query eq 'HASH' && ref $query->{dbsearch} eq 'HASH' ) {
        my $operands = $query->{dbsearch}->{operands} || [];
        my $indexes  = $query->{dbsearch}->{indexes}  || [];
        if ( @{$operands} ) {
            my @terms;
            for my $i ( 0 .. $#{$operands} ) {
                my $operand = $operands->[$i];
                next unless defined $operand && $operand =~ /\S/;
                my $index = $indexes->[$i] // 'kw';
                next if Koha::Plugin::HKS3::NM2DBKeywordSearch->derived_limit_from_koha_limit($operand);
                next if Koha::Plugin::HKS3::NM2DBKeywordSearch->derived_limit_from_koha_limit( $index . '=' . $operand );
                push @terms, $operand;
            }
            $keyword = join q{ }, @terms;
        }
        else {
            $keyword = $query->{dbsearch}->{query} // $simple_query // q{};
        }
    }
    else {
        $keyword = $simple_query // $query // q{};
    }
    return q{} if Koha::Plugin::HKS3::NM2DBKeywordSearch->derived_limit_from_koha_limit($keyword);
    $keyword =~ s/\A\s+|\s+\z//g;
    $keyword =~ s/\b(?:kw|ti|au|su|nb|ns|se|an|Control-number)[:=]//g;
    $keyword =~ s/\s+/ /g;

    return $keyword;
}

sub _has_filter_query {
    my ( $self, $facet_name, $facet_value, $filter_options ) = @_;

    return 1
        if defined $facet_name
        && length $facet_name
        && defined $facet_value
        && length $facet_value;
    return 1 if $filter_options->{refine};
    return 1 if $filter_options->{available_only};
    return 1 if $filter_options->{derived_limits} && @{ $filter_options->{derived_limits} };

    return 0;
}

sub _filters_from_query {
    my ( $self, $query ) = @_;

    my $filters = {};
    my ( $facet_name, $facet_value );
    my @refine_terms;
    my @derived_limits;
    my $limits = ref $query eq 'HASH' && ref $query->{dbsearch} eq 'HASH'
        ? $query->{dbsearch}->{limits} || []
        : [];

    if ( ref $query eq 'HASH' && ref $query->{dbsearch} eq 'HASH' ) {
        my $operands = $query->{dbsearch}->{operands} || [];
        my $indexes  = $query->{dbsearch}->{indexes}  || [];
        for my $i ( 0 .. $#{$operands} ) {
            my $operand = $operands->[$i];
            next unless defined $operand && $operand =~ /\S/;
            my $index = $indexes->[$i] // 'kw';
            if ( my $derived_limit = Koha::Plugin::HKS3::NM2DBKeywordSearch->derived_limit_from_koha_limit($operand) ) {
                push @derived_limits, $derived_limit;
                next;
            }
            if ( my $derived_limit = Koha::Plugin::HKS3::NM2DBKeywordSearch->derived_limit_from_koha_limit( $index . '=' . $operand ) ) {
                push @derived_limits, $derived_limit;
            }
        }
    }

    for my $limit ( @{$limits} ) {
        next unless defined $limit && length $limit;

        if ( $limit eq 'available' ) {
            $filters->{available_only} = 1;
            next;
        }

        if ( my $derived_limit = Koha::Plugin::HKS3::NM2DBKeywordSearch->derived_limit_from_koha_limit($limit) ) {
            push @derived_limits, $derived_limit;
            next;
        }

        if ( $limit !~ /\A([^:]+):(.+)\z/ ) {
            push @refine_terms, $limit;
            next;
        }

        my ( $limit_name, $limit_value ) = ( $1, $2 );
        if ( $self->_is_search_within_index($limit_name) ) {
            push @refine_terms, $limit_value;
            next;
        }

        next if defined $facet_name && defined $facet_value;
        ( $facet_name, $facet_value ) = ( $limit_name, $limit_value );
        $facet_value =~ s/\A"(.*)"\z/$1/;
        $facet_value =~ s/\\"/"/g;
    }

    $filters->{refine} = join q{ }, @refine_terms if @refine_terms;
    $filters->{derived_limits} = \@derived_limits if @derived_limits;

    return ( $facet_name, $facet_value, $filters );
}

sub _is_search_within_index {
    my ( $self, $index ) = @_;

    return 0 unless defined $index && length $index;
    $index =~ s/,phr\z//;

    my %indexes = map { $_ => 1 } qw(
        kw ti au su nb ns se an cpn cfn pn nt
        Control-number
    );

    return $indexes{$index} ? 1 : 0;
}

sub _convert_facets {
    my ( $self, $plugin_facets ) = @_;

    return [] unless $plugin_facets && @{$plugin_facets};

    my @facets;
    for my $group ( @{$plugin_facets} ) {
        my $type = $group->{name} // q{};
        next unless length $type;
        my $label = $group->{label} || $type;
        my $type_id = lc $type;
        $type_id =~ s/[^a-z0-9]+/_/g;
        $type_id =~ s/\A_+|_+\z//g;
        $type_id ||= 'dbsearch';

        push @facets, {
            type_id         => $type_id . '_id',
            type_link_value => $type,
            label           => $label,
            "type_label_$label" => 1,
            facets          => [
                map {
                    +{
                        facet_count       => $_->{count},
                        facet_label_value => $_->{value},
                        facet_title_value => $_->{value},
                        facet_link_value  => $_->{value},
                        type_link_value   => $type,
                    }
                } @{ $group->{values} || [] }
            ],
        };
    }

    return \@facets;
}

sub _zebra_searcher {
    require Koha::SearchEngine::Zebra::Search;
    return Koha::SearchEngine::Zebra::Search->new( { index => $_[0]->index } );
}

1;
