package Koha::SearchEngine::DBSearch::Search;

use Modern::Perl;

use base qw(Class::Accessor);

use C4::AuthoritiesMarc ();
use C4::Context;
use MARC::Record;
use Koha::Authorities;
use Koha::Authority::Types;
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
    my ( $self, $query, $offset, $count, $skipmetadata ) = @_;

    return $self->_zebra_searcher->search_auth_compat( $query, $offset, $count, $skipmetadata )
        unless ( C4::Context->preference('marcflavour') // q{} ) eq 'MARC21';

    $query ||= {};
    # The authority compatibility API uses one-based record offsets.
    $offset = ( $offset // 1 ) - 1;
    $offset = 0 if $offset < 0;
    $count //= 10;
    $count = 1 if $count < 1;

    my $dbh = C4::Context->dbh;
    my ( $where, $bind ) = $self->_authority_where_sql($query);
    my $heading = $self->_authority_heading_sql('r');
    my $order   = $self->_authority_order_by_sql( $query->{orderby} );

    my $from = qq{
        FROM nm2db_records r
        JOIN auth_header ah
            ON ah.authid = r.authid
        LEFT JOIN auth_types at
            ON at.authtypecode = ah.authtypecode
        WHERE r.type = 'authority'
        $where
    };

    my ($total) = $dbh->selectrow_array(
        qq{SELECT COUNT(*) $from},
        undef,
        @{$bind}
    );

    my $rows = $dbh->selectall_arrayref(
        qq{
            SELECT r.authid, ah.authtypecode, $heading AS heading
            $from
            ORDER BY $order
            LIMIT ? OFFSET ?
        },
        { Slice => {} },
        @{$bind}, $count, $offset
    );

    my @results;
    for my $position ( 0 .. $#{$rows} ) {
        my $result = $self->_authority_result( $rows->[$position], $skipmetadata, $position );
        push @results, $result if $result;
    }

    return ( \@results, 0 + ( $total // 0 ) );
}

sub _authority_where_sql {
    my ( $self, $query ) = @_;

    my $marclist = $query->{marclist} || [];
    my $and_or   = $query->{and_or}   || [];
    my $excluding = $query->{excluding} || [];
    my $operator = $query->{operator} || [];
    my $values   = $query->{value}    || [];

    my @conditions;
    my @bind;
    for my $i ( 0 .. $#{$values} ) {
        next unless defined $values->[$i] && $values->[$i] =~ /\S/;

        my ( $condition, $term_bind ) = $self->_authority_term_sql(
            $marclist->[$i],
            $operator->[$i],
            $values->[$i]
        );
        next unless $condition;

        $condition = qq{NOT ($condition)} if $excluding->[$i];
        if (@conditions) {
            my $join = lc( $and_or->[$i] // 'and' ) eq 'or' ? 'OR' : 'AND';
            push @conditions, $join;
        }
        push @conditions, "($condition)";
        push @bind, @{$term_bind};
    }

    my @where;
    push @where, join q{ }, @conditions if @conditions;

    if ( defined $query->{authtypecode} && $query->{authtypecode} =~ /\S/ ) {
        my @types = grep { length } split /\s+/, $query->{authtypecode};
        if (@types) {
            push @where, 'ah.authtypecode IN (' . join( q{,}, ('?') x @types ) . ')';
            push @bind, @types;
        }
    }

    return ( @where ? 'AND ' . join( ' AND ', @where ) : q{}, \@bind );
}

sub _authority_term_sql {
    my ( $self, $marclist, $operator, $value ) = @_;

    $marclist //= q{};
    $operator //= 'contains';

    if ( $marclist eq 'authtype' ) {
        return $self->_authority_value_condition_sql( 'ah.authtypecode', $operator, $value );
    }
    if ( $marclist =~ /\A(?:Local-number|authid)\z/i ) {
        return $self->_authority_value_condition_sql( 'r.authid', $operator, $value );
    }
    if ( $marclist eq 'Heading-use-main-or-added-entry' ) {
        return $self->_authority_control_value_sql( 15, $operator, $value );
    }
    if ( $marclist eq 'Heading-use-subject-added-entry' ) {
        return $self->_authority_control_value_sql( 16, $operator, $value );
    }
    if ( $marclist eq 'Heading-use-series-added-entry' ) {
        return $self->_authority_control_value_sql( 17, $operator, $value );
    }
    if ( $marclist eq 'thesaurus' ) {
        return $self->_authority_thesaurus_sql( $operator, $value );
    }

    my @field_conditions;
    if ( $marclist eq 'mainentry' || $marclist eq 'match-heading' ) {
        push @field_conditions, 'BINARY authority_f.tag = BINARY at.auth_tag_to_report';
    } elsif ( $marclist eq 'mainmainentry' ) {
        push @field_conditions, 'BINARY authority_f.tag = BINARY at.auth_tag_to_report';
        push @field_conditions, q{COALESCE(authority_s.code, '') = 'a'};
    } elsif ( $marclist eq 'see-from' ) {
        push @field_conditions, q{authority_f.tag REGEXP '^4[0-9]{2}$'};
    } elsif ( $marclist eq 'match' ) {
        push @field_conditions, q{(BINARY authority_f.tag = BINARY at.auth_tag_to_report OR authority_f.tag REGEXP '^[45][0-9]{2}$')};
    } elsif ( $marclist =~ /\A(\d{3})([0-9A-Za-z])?\z/ ) {
        push @field_conditions, q{authority_f.tag = '} . $1 . q{'};
        push @field_conditions, q{COALESCE(authority_s.code, '') = '} . $2 . q{'} if defined $2;
    } elsif ( $marclist eq 'LC-card-number' ) {
        push @field_conditions, q{authority_f.tag = '010'};
        push @field_conditions, q{COALESCE(authority_s.code, '') = 'a'};
    } elsif ( $marclist eq 'Other-control-number' ) {
        push @field_conditions, q{authority_f.tag = '035'};
    }

    my ( $value_condition, $bind ) = $self->_authority_value_condition_sql( 'authority_s.value', $operator, $value );
    my $field_condition = @field_conditions ? 'AND ' . join( ' AND ', @field_conditions ) : q{};
    return (
        qq{
            EXISTS (
                SELECT 1
                FROM nm2db_fields authority_f
                JOIN nm2db_subfields authority_s
                    ON authority_s.field_id = authority_f.id
                WHERE authority_f.record_id = r.id
                  $field_condition
                  AND $value_condition
            )
        },
        $bind
    );
}

sub _authority_control_value_sql {
    my ( $self, $position, $operator, $value ) = @_;

    my ( $value_condition, $bind ) =
        $self->_authority_value_condition_sql( qq{SUBSTRING(authority_008_s.value, $position, 1)}, $operator, $value );
    return (
        qq{
            EXISTS (
                SELECT 1
                FROM nm2db_fields authority_008_f
                JOIN nm2db_subfields authority_008_s
                    ON authority_008_s.field_id = authority_008_f.id
                WHERE authority_008_f.record_id = r.id
                  AND authority_008_f.tag = '008'
                  AND $value_condition
            )
        },
        $bind
    );
}

sub _authority_thesaurus_sql {
    my ( $self, $operator, $value ) = @_;

    my $thesaurus = q{
        CASE SUBSTRING(authority_008_s.value, 12, 1)
            WHEN 'a' THEN 'lcsh'
            WHEN 'b' THEN 'lcac'
            WHEN 'c' THEN 'mesh'
            WHEN 'd' THEN 'nal'
            WHEN 'k' THEN 'cash'
            WHEN 'n' THEN 'notapplicable'
            WHEN 'r' THEN 'aat'
            WHEN 's' THEN 'sears'
            WHEN 'v' THEN 'rvm'
            WHEN 'z' THEN COALESCE((
                SELECT authority_040_s.value
                FROM nm2db_fields authority_040_f
                JOIN nm2db_subfields authority_040_s
                    ON authority_040_s.field_id = authority_040_f.id
                WHERE authority_040_f.record_id = r.id
                  AND authority_040_f.tag = '040'
                  AND authority_040_s.code = 'f'
                LIMIT 1
            ), 'notdefined')
            ELSE 'notspecified'
        END
    };
    my ( $value_condition, $bind ) = $self->_authority_value_condition_sql( $thesaurus, $operator, $value );
    return (
        qq{
            EXISTS (
                SELECT 1
                FROM nm2db_fields authority_008_f
                JOIN nm2db_subfields authority_008_s
                    ON authority_008_s.field_id = authority_008_f.id
                WHERE authority_008_f.record_id = r.id
                  AND authority_008_f.tag = '008'
                  AND $value_condition
            )
        },
        $bind
    );
}

sub _authority_value_condition_sql {
    my ( $self, $column, $operator, $value ) = @_;

    $operator //= 'contains';
    if ( $operator eq 'is' || $operator eq 'exact' || $operator eq '=' ) {
        return ( "$column = ?", [$value] );
    }

    $value =~ s/([=%_])/=$1/g;
    my $pattern = $operator eq 'start' || $operator eq 'starts'
        ? $value . '%'
        : '%' . $value . '%';
    return ( "$column LIKE ? ESCAPE '='", [$pattern] );
}

sub _authority_heading_sql {
    my ( $self, $record_alias ) = @_;

    return qq{
        COALESCE((
            SELECT GROUP_CONCAT(authority_heading_s.value ORDER BY authority_heading_f.sequence, authority_heading_s.sequence SEPARATOR ' ')
            FROM nm2db_fields authority_heading_f
            JOIN nm2db_subfields authority_heading_s
                ON authority_heading_s.field_id = authority_heading_f.id
            WHERE authority_heading_f.record_id = $record_alias.id
              AND BINARY authority_heading_f.tag = BINARY at.auth_tag_to_report
        ), '')
    };
}

sub _authority_order_by_sql {
    my ( $self, $orderby ) = @_;

    return 'heading DESC, r.authid DESC' if ( $orderby // q{} ) eq 'HeadingDsc';
    return 'heading ASC, r.authid ASC'   if ( $orderby // q{} ) eq 'HeadingAsc';
    return 'r.authid DESC'               if ( $orderby // q{} ) eq 'AuthidDsc';
    return 'r.authid ASC';
}

sub _authority_result {
    my ( $self, $row, $skipmetadata, $position ) = @_;

    my $authid = $row->{authid};
    my %result = ( authid => $authid );
    return \%result if $skipmetadata;

    my $authority = Koha::Authorities->find($authid);
    return \%result unless $authority;

    my $record = eval { $authority->record };
    return \%result unless $record;

    my $authtypecode = $authority->authtypecode;
    my $authtype = Koha::Authority::Types->find($authtypecode);
    my $reported_tag = q{};
    if ( $authtype && ( my $mainentry = $record->field( $authtype->auth_tag_to_report ) ) ) {
        $reported_tag .= '$' . $_->[0] . $_->[1] for $mainentry->subfields();
    }

    if ( C4::Context->preference('ShowHeadingUse') ) {
        if ( my $field_008 = $record->field('008') ) {
            my $heading_use = substr( $field_008->data, 14, 3 );
            $result{main}    = 1 if substr( $heading_use, 0, 1 ) eq 'a';
            $result{subject} = 1 if substr( $heading_use, 1, 1 ) eq 'a';
            $result{series}  = 1 if substr( $heading_use, 2, 1 ) eq 'a';
        }
    }

    $result{authtype}     = $authtype ? $authtype->authtypetext : $authtypecode;
    $result{summary}      = C4::AuthoritiesMarc::BuildSummary( $record, $authid, $authtypecode );
    $result{reported_tag} = $reported_tag;
    $result{even}         = $position % 2;
    $result{used}         = $self->_authority_usage_count($authid);

    return \%result;
}

sub _authority_usage_count {
    my ( $self, $authid ) = @_;

    my ($count) = C4::Context->dbh->selectrow_array(
        q{
            SELECT COUNT(DISTINCT r.biblionumber)
            FROM nm2db_records r
            JOIN nm2db_fields f
                ON f.record_id = r.id
            JOIN nm2db_subfields s
                ON s.field_id = f.id
            WHERE r.type = 'biblio'
              AND s.code = '9'
              AND s.value = ?
        },
        undef,
        $authid
    );

    return 0 + ( $count // 0 );
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
