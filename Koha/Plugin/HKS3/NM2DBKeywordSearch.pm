package Koha::Plugin::HKS3::NM2DBKeywordSearch;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use CGI;
use C4::Auth qw(get_template_and_user);
use C4::Biblio qw(GetXmlBiblio);
use C4::Context;
use C4::Koha qw(getFacets);
use C4::Templates;
use C4::XSLT;
use Cwd qw(abs_path);
use Mojo::JSON qw(decode_json encode_json);
use Koha::Biblios;

our $VERSION = '0.05';

our $metadata = {
    name            => 'NM2DB Keyword Search',
    author          => 'Mark Hofstetter',
    description     => 'Adds OPAC and intranet keyword search pages for nm2db_v_record',
    namespace       => 'nm2db_keyword_search',
    date_authored   => '2026-03-24',
    date_updated    => '2026-03-24',
    minimum_version => '23.11',
    maximum_version => undef,
    version         => $VERSION,
};

my $FULLTEXT_MIN_TOKEN_SIZE;
my $FULLTEXT_STOPWORDS;

sub new {
    my ( $class, $args ) = @_;

    $args->{metadata}         = $metadata;
    $args->{metadata}{class}  = $class;

    my $self = $class->SUPER::new($args);
    $self->{cgi} = CGI->new();

    return $self;
}

sub install {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;

    $self->_ensure_index(
        $dbh,
        'nm2db_subfields',
        'ft_subfield_value',
        q{ALTER TABLE nm2db_subfields ADD FULLTEXT INDEX ft_subfield_value (value)}
    );
    $self->_ensure_index(
        $dbh,
        'nm2db_records',
        'nm2db_records_type_id_biblio_idx',
        q{ALTER TABLE nm2db_records ADD INDEX nm2db_records_type_id_biblio_idx (type, id, biblionumber)}
    );
    $self->_ensure_index(
        $dbh,
        'nm2db_fields',
        'nm2db_fields_record_tag_id_idx',
        q{ALTER TABLE nm2db_fields ADD INDEX nm2db_fields_record_tag_id_idx (record_id, tag, id)}
    );
    $self->_ensure_index(
        $dbh,
        'nm2db_subfields',
        'nm2db_subfields_field_code_value_idx',
        q{ALTER TABLE nm2db_subfields ADD INDEX nm2db_subfields_field_code_value_idx (field_id, code, value(191))}
    );
    $self->_ensure_index(
        $dbh,
        'search_marc_to_field',
        'nm2db_keyword_smtf_search_idx',
        q{ALTER TABLE search_marc_to_field ADD INDEX nm2db_keyword_smtf_search_idx (search, search_marc_map_id, search_field_id)}
    );
    $self->_ensure_index(
        $dbh,
        'search_marc_to_field',
        'nm2db_keyword_smtf_facet_idx',
        q{ALTER TABLE search_marc_to_field ADD INDEX nm2db_keyword_smtf_facet_idx (facet, search_marc_map_id, search_field_id)}
    );
    $self->_ensure_index(
        $dbh,
        'items',
        'nm2db_items_availability_idx',
        q{ALTER TABLE items ADD INDEX nm2db_items_availability_idx (biblionumber, onloan, itemlost, withdrawn, notforloan)}
    );

    $self->_create_keyword_lookup_tables($dbh);
    $self->configure_zebra_like_facet_settings($dbh);
    $self->_refresh_keyword_lookup_tables($dbh);

    return 1;
}

sub uninstall {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do(q{DROP TABLE IF EXISTS nm2db_keyword_search_derived_values});
    $dbh->do(q{DROP TABLE IF EXISTS nm2db_keyword_search_facet_values});
    $dbh->do(q{DROP TABLE IF EXISTS nm2db_keyword_search_suggestions});
    $dbh->do(q{DROP TABLE IF EXISTS nm2db_keyword_search_facets});
    $dbh->do(q{DROP TABLE IF EXISTS nm2db_keyword_search_weights});

    $self->_drop_index_if_exists( $dbh, 'items', 'nm2db_items_availability_idx' );
    $self->_drop_index_if_exists( $dbh, 'search_marc_to_field', 'nm2db_keyword_smtf_facet_idx' );
    $self->_drop_index_if_exists( $dbh, 'search_marc_to_field', 'nm2db_keyword_smtf_search_idx' );
    $self->_drop_index_if_exists( $dbh, 'nm2db_subfields', 'nm2db_subfields_field_code_value_idx' );
    $self->_drop_index_if_exists( $dbh, 'nm2db_fields', 'nm2db_fields_record_tag_id_idx' );
    $self->_drop_index_if_exists( $dbh, 'nm2db_records', 'nm2db_records_type_id_biblio_idx' );
    $self->_drop_index_if_exists( $dbh, 'nm2db_subfields', 'ft_subfield_value' );

    return 1;
}

sub api_namespace {
    return 'nm2db_keyword_search';
}

sub api_routes {
    my ($self) = @_;

    return decode_json( $self->mbf_read('openapi.json') );
}

sub static_routes {
    my ($self) = @_;

    return decode_json( $self->mbf_read('staticapi.json') );
}

sub tool {
    my ($self) = @_;
    my $template = $self->get_template({ file => 'search-page.tt' });
    $template->param(
        api_search_url      => $self->opac_search_url,
        api_suggestions_url => $self->suggestions_url,
    );

    $self->output_html( $template->output() );
}

sub get_opac_template {
    my ($self) = @_;

    my ( $template ) = get_template_and_user(
        {
            template_name   => abs_path( $self->mbf_path('opac.tt') ),
            query           => $self->{cgi},
            type            => 'opac',
            authnotrequired => 1,
            is_plugin       => 1,
        }
    );

    $template->param(
        CLASS      => $self->{class},
        PLUGIN_DIR => $self->bundle_path,
    );

    return $template;
}

sub render_opac_page {
    my ( $self, $keyword, $facet_name, $facet_value, $options ) = @_;

    my $template = $self->get_opac_template;
    $options ||= {};
    my $results = $self->search_records( $keyword, $facet_name, $facet_value, $options );
    $results = $self->add_rendered_html( $results, 'opac' );
    my $facets = $self->search_facets( $keyword, $facet_name, $facet_value, $options );

    $template->param(
        keyword               => $keyword,
        refine                => $options->{refine} // q{},
        available_only        => $options->{available_only} ? 1 : 0,
        results               => $results,
        facets                => $facets,
        selected_facet_name   => $facet_name,
        selected_facet_value  => $facet_value,
        intranet_plugin_url   => $self->intranet_tool_url,
        api_suggestions_url   => $self->suggestions_url,
    );

    return $template->output;
}

sub opac_search_url {
    return '/api/v1/contrib/nm2db_keyword_search/search';
}

sub opac_page_url {
    return '/api/v1/contrib/nm2db_keyword_search/page';
}

sub ui_search_url {
    return '/api/v1/contrib/nm2db_keyword_search/static/ui/search.html';
}

sub suggestions_url {
    return '/api/v1/contrib/nm2db_keyword_search/suggestions';
}

sub intranet_tool_url {
    return '/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::HKS3::NM2DBKeywordSearch&method=tool';
}

sub opac_js {
    my ($self) = @_;

    return $self->_catalogue_typeahead_js(
        {
            search_path => '/cgi-bin/koha/opac-search.pl',
            detail_url  => '/cgi-bin/koha/opac-detail.pl?biblionumber=',
        }
    );
}

sub intranet_js {
    my ($self) = @_;

    return $self->_catalogue_typeahead_js(
        {
            search_path => '/cgi-bin/koha/catalogue/search.pl',
            detail_url  => '/cgi-bin/koha/catalogue/detail.pl?biblionumber=',
        }
    );
}

sub koha_search_engine {
    return {
        code                => 'DBSearch',
        label               => 'DBSearch',
        search_class        => 'Koha::SearchEngine::DBSearch::Search',
        query_builder_class => 'Koha::SearchEngine::DBSearch::QueryBuilder',
        indexer_class       => 'Koha::SearchEngine::DBSearch::Indexer',
    };
}

sub configure_zebra_like_facet_settings {
    my ( $self, $dbh ) = @_;

    $dbh ||= C4::Context->dbh;

    my $marc_type = lc( C4::Context->preference('marcflavour') || 'MARC21' );
    my $facets = getFacets();
    my %idx_to_search_field = (
        au    => 'author',
        se    => 'title-series',
        'su-to'  => 'subject',
        'su-ut'  => 'su-ut',
        'su-geo' => 'su-geo',
    );

    $dbh->do(
        q{
            UPDATE search_marc_to_field smtf
            JOIN search_marc_map smm
                ON smm.id = smtf.search_marc_map_id
            SET smtf.facet = 0
            WHERE smm.index_name = 'biblios'
              AND smm.marc_type = ?
        },
        undef,
        $marc_type
    );

    my $facet_order = 1;
    for my $facet ( @{$facets} ) {
        my $field_name = $idx_to_search_field{ $facet->{idx} } || $facet->{idx};
        my $label = $facet->{label} || $field_name;
        my $search_field_id = $self->_ensure_search_field( $dbh, $field_name, $label, $facet_order++ );

        for my $marc_field ( $self->_facet_marc_fields( $facet->{tags} ) ) {
            my $search_marc_map_id = $self->_ensure_search_marc_map( $dbh, $marc_type, $marc_field );
            $self->_enable_search_marc_facet( $dbh, $search_marc_map_id, $search_field_id );
        }
    }

    return 1;
}

sub _catalogue_typeahead_js {
    my ( $self, $config ) = @_;

    my $json = encode_json(
        {
            suggestionsUrl => $self->suggestions_url,
            searchPath     => $config->{search_path},
            detailUrl      => $config->{detail_url},
            minChars       => 2,
            limit          => 10,
        }
    );
    $json =~ s{<}{\\u003c}g;

    my $script = <<'JS';
<script>
(function(config) {
    if (window.nm2dbCatalogueTypeaheadLoaded) {
        return;
    }
    window.nm2dbCatalogueTypeaheadLoaded = true;

    const inputState = new WeakMap();
    let sequence = 0;

    function stateFor(input) {
        if (!inputState.has(input)) {
            inputState.set(input, {
            controller: null,
            datalist: null,
            suggestions: new Map(),
            timer: null,
            explicitSelection: false,
        });
        }
        return inputState.get(input);
    }

    function formUsesCatalogueSearch(form) {
        if (!form) {
            return false;
        }
        const action = form.getAttribute("action") || window.location.pathname;
        try {
            return new URL(action, window.location.href).pathname === config.searchPath;
        } catch (_error) {
            return false;
        }
    }

    function catalogueInputs() {
        return Array.from(document.querySelectorAll("form"))
            .filter(formUsesCatalogueSearch)
            .flatMap((form) => Array.from(form.querySelectorAll(
                'input[name="q"]:not([type="hidden"]):not([type="submit"]):not([type="button"]):not([type="checkbox"]):not([type="radio"]), textarea[name="q"]'
            )));
    }

    function ensureDatalist(input) {
        const state = stateFor(input);
        if (state.datalist) {
            return state.datalist;
        }

        const datalist = document.createElement("datalist");
        datalist.id = `nm2db-catalogue-typeahead-${++sequence}`;
        input.setAttribute("list", datalist.id);
        input.setAttribute("autocomplete", "off");
        input.insertAdjacentElement("afterend", datalist);
        state.datalist = datalist;

        return datalist;
    }

    function escapeAttribute(value) {
        return String(value)
            .replace(/&/g, "&amp;")
            .replace(/"/g, "&quot;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;");
    }

    function rememberSuggestions(input, suggestions) {
        const state = stateFor(input);
        state.suggestions = new Map();
        state.explicitSelection = false;
        suggestions.forEach((entry) => {
            const value = entry && entry.value ? String(entry.value) : "";
            if (value && !state.suggestions.has(value)) {
                state.suggestions.set(value, entry);
            }
        });
    }

    function selectedSuggestion(input) {
        return stateFor(input).suggestions.get(input.value.trim());
    }

    function recordUrl(entry) {
        const biblionumber = entry && entry.biblionumber ? String(entry.biblionumber) : "";
        return biblionumber ? `${config.detailUrl}${encodeURIComponent(biblionumber)}` : "";
    }

    function redirectSelected(input, event) {
        if (!stateFor(input).explicitSelection) {
            return false;
        }
        const url = recordUrl(selectedSuggestion(input));
        if (!url) {
            return false;
        }
        if (event) {
            event.preventDefault();
        }
        window.location.assign(url);
        return true;
    }

    function renderSuggestions(input, suggestions) {
        const datalist = ensureDatalist(input);
        rememberSuggestions(input, suggestions);
        datalist.innerHTML = suggestions.map((entry) => {
            const field = entry.field || "";
            const count = entry.count ? ` (${entry.count})` : "";
            const direct = entry.biblionumber ? ` #${entry.biblionumber}` : "";
            return `<option value="${escapeAttribute(entry.value || "")}" label="${escapeAttribute(field + direct + count)}"></option>`;
        }).join("");
    }

    async function loadSuggestions(input) {
        const state = stateFor(input);
        const term = input.value.trim();

        if (state.controller) {
            state.controller.abort();
            state.controller = null;
        }

        if (term.length < config.minChars) {
            renderSuggestions(input, []);
            return;
        }

        const controller = new AbortController();
        state.controller = controller;
        const params = new URLSearchParams({
            term,
            limit: String(config.limit),
        });
        const response = await fetch(`${config.suggestionsUrl}?${params.toString()}`, {
            headers: { Accept: "application/json" },
            signal: controller.signal,
        });
        if (!response.ok) {
            return;
        }

        const payload = await response.json();
        if (state.controller !== controller) {
            return;
        }
        renderSuggestions(input, Array.isArray(payload.suggestions) ? payload.suggestions : []);
    }

    function queueSuggestions(input) {
        const state = stateFor(input);
        window.clearTimeout(state.timer);
        state.timer = window.setTimeout(() => {
            loadSuggestions(input).catch((error) => {
                if (error.name !== "AbortError") {
                    renderSuggestions(input, []);
                }
            });
        }, 180);
    }

    function attachInput(input) {
        if (input.dataset.nm2dbCatalogueTypeahead === "1") {
            return;
        }
        input.dataset.nm2dbCatalogueTypeahead = "1";
        ensureDatalist(input);
        input.addEventListener("input", (event) => {
            stateFor(input).explicitSelection = event.inputType === "insertReplacementText";
            queueSuggestions(input);
            if (event.inputType === "insertReplacementText") {
                redirectSelected(input, event);
            }
        });
    }

    function attachForm(form) {
        if (!formUsesCatalogueSearch(form) || form.dataset.nm2dbCatalogueTypeahead === "1") {
            return;
        }
        form.dataset.nm2dbCatalogueTypeahead = "1";
    }

    function attachAll() {
        catalogueInputs().forEach(attachInput);
        Array.from(document.querySelectorAll("form")).forEach(attachForm);
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", attachAll);
    } else {
        attachAll();
    }
    new MutationObserver(attachAll).observe(document.documentElement, {
        childList: true,
        subtree: true,
    });
}(__CONFIG__));
</script>
JS

    $script =~ s/__CONFIG__/$json/;
    return $script;
}

sub search_records {
    my ( $self, $keyword, $facet_name, $facet_value, $options ) = @_;

    $options ||= {};
    my $refine = $self->_normalized_search_option( $options->{refine} );
    my $available_only = $options->{available_only} ? 1 : 0;
    my $derived_limits = $self->_normalized_derived_limits( $options->{derived_limits} );
    my $has_keyword = defined $keyword && $keyword =~ /\S/ ? 1 : 0;
    return [] unless $has_keyword || $self->_has_record_filters( $facet_name, $facet_value, $refine, $available_only, $derived_limits );

    my $dbh = C4::Context->dbh;
    return $self->_filtered_record_rows( $dbh, $facet_name, $facet_value, $options, $refine, $available_only, $derived_limits )
        unless $has_keyword;

    my $exact_hits = $self->_should_use_exact_title_shortcut($keyword)
        ? $self->_exact_suggestion_hits( $dbh, $keyword )
        : [];
    if ( @{$exact_hits} ) {
        $exact_hits = $self->_filter_hits_by_facet( $dbh, $exact_hits, $facet_name, $facet_value );
        $exact_hits = $self->_filter_hits_by_derived_limits( $dbh, $exact_hits, $derived_limits );
        $exact_hits = $self->_filter_hits_by_refine( $dbh, $exact_hits, $refine );
        $exact_hits = $self->_filter_hits_by_availability( $dbh, $exact_hits, $available_only );
        return $self->_exact_suggestion_result_rows( $dbh, $exact_hits, $options );
    }

    my $plain_terms = $self->_opac_like_index_terms( $dbh, $keyword );
    return [] if defined $plain_terms && !@{$plain_terms};
    my $boolean_search = $self->_opac_like_boolean_query( $keyword, $plain_terms );
    my $search = $dbh->quote($boolean_search);
    my $eligible_record_join = $self->_opac_like_eligible_record_join_sql( $dbh, 'r', $plain_terms, $search );
    my ( $refine_record_filter, $refine_has_no_terms ) = $self->_record_fulltext_filter_sql( $dbh, 'r', $refine, 'refine' );
    return [] if $refine_has_no_terms;
    my $available_record_filter = $available_only ? $self->_available_items_filter_sql('r') : q{};
    my $derived_record_filter = $self->_derived_record_filter_sql( $dbh, 'r', $derived_limits, 'derived' );
    my $facet_name_sql  = defined $facet_name  && length $facet_name  ? $dbh->quote($facet_name)  : undef;
    my $facet_value_sql = defined $facet_value && length $facet_value ? $dbh->quote($facet_value) : undef;
    my $metadata_select = $options->{include_xml} ? 'bm.metadata AS xml' : 'NULL AS xml';
    my $metadata_join = $options->{include_xml}
        ? q{
        LEFT JOIN biblio_metadata bm
            ON bm.biblionumber = m.biblionumber
           AND bm.format = 'marcxml'
        }
        : q{};
    my $metadata_group = $options->{include_xml} ? ', bm.metadata' : q{};
    my $limit = int( $options->{limit} // 200 );
    $limit = 1 if $limit < 1;
    $limit = 1000 if $limit > 1000;
    my $offset = int( $options->{offset} // 0 );
    $offset = 0 if $offset < 0;
    my $sql = qq{
        SELECT
            m.biblionumber,
            SUM(m.weight) AS weight_sum,
            MAX(m.relevance) AS relevance,
            GROUP_CONCAT( DISTINCT m.tag ORDER BY m.tag SEPARATOR ', ' ) AS tag,
            GROUP_CONCAT( DISTINCT m.display_value ORDER BY m.tag, m.raw_value SEPARATOR '\n' ) AS value,
            $metadata_select
        FROM (
            SELECT
                r.id AS record_id,
                r.biblionumber,
                f.tag,
                COALESCE(s.code, '') AS code,
                s.value AS raw_value,
                COALESCE(sw.weight, 0) AS weight,
                MATCH(s.value) AGAINST($search IN boolean MODE) AS relevance,
                CONCAT(f.tag, COALESCE(s.code, ''), ' [w=', COALESCE(sw.weight, 0), ']: ', s.value) AS display_value
            FROM nm2db_records r
            $eligible_record_join
            JOIN nm2db_fields f
                ON f.record_id = r.id
            JOIN nm2db_subfields s
                ON s.field_id = f.id
            LEFT JOIN nm2db_keyword_search_weights sw
                ON sw.tag = f.tag
               AND sw.code = COALESCE(s.code, '')
            WHERE r.type = 'biblio'
              $refine_record_filter
              $available_record_filter
              $derived_record_filter
              AND MATCH(s.value) AGAINST($search IN boolean MODE)
        ) m
        $metadata_join
        WHERE 1 = 1
    };

    if ( defined $facet_name_sql && defined $facet_value_sql ) {
        $sql .= qq{
          AND EXISTS (
              SELECT 1
              FROM nm2db_keyword_search_facet_values sf2
              WHERE sf2.record_id = m.record_id
                AND sf2.name = $facet_name_sql
                AND sf2.value = $facet_value_sql
          )
        };
    }

    $sql .= qq{
        GROUP BY m.biblionumber $metadata_group
        ORDER BY weight_sum DESC, relevance DESC, m.biblionumber
        LIMIT $limit OFFSET $offset
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute();

    return $sth->fetchall_arrayref({});
}

sub count_records {
    my ( $self, $keyword, $facet_name, $facet_value, $options ) = @_;

    $options ||= {};
    my $refine = $self->_normalized_search_option( $options->{refine} );
    my $available_only = $options->{available_only} ? 1 : 0;
    my $derived_limits = $self->_normalized_derived_limits( $options->{derived_limits} );
    my $has_keyword = defined $keyword && $keyword =~ /\S/ ? 1 : 0;
    return 0 unless $has_keyword || $self->_has_record_filters( $facet_name, $facet_value, $refine, $available_only, $derived_limits );

    my $dbh = C4::Context->dbh;
    return $self->_count_filtered_records( $dbh, $facet_name, $facet_value, $refine, $available_only, $derived_limits )
        unless $has_keyword;

    my $exact_hits = $self->_should_use_exact_title_shortcut($keyword)
        ? $self->_exact_suggestion_hits( $dbh, $keyword )
        : [];
    if ( @{$exact_hits} ) {
        $exact_hits = $self->_filter_hits_by_facet( $dbh, $exact_hits, $facet_name, $facet_value );
        $exact_hits = $self->_filter_hits_by_derived_limits( $dbh, $exact_hits, $derived_limits );
        $exact_hits = $self->_filter_hits_by_refine( $dbh, $exact_hits, $refine );
        $exact_hits = $self->_filter_hits_by_availability( $dbh, $exact_hits, $available_only );
        return scalar @{$exact_hits};
    }

    my $plain_terms = $self->_opac_like_index_terms( $dbh, $keyword );
    return 0 if defined $plain_terms && !@{$plain_terms};
    my $boolean_search = $self->_opac_like_boolean_query( $keyword, $plain_terms );
    my $search = $dbh->quote($boolean_search);
    my $eligible_record_join = $self->_opac_like_eligible_record_join_sql( $dbh, 'r', $plain_terms, $search );
    my ( $refine_record_filter, $refine_has_no_terms ) = $self->_record_fulltext_filter_sql( $dbh, 'r', $refine, 'refine_count' );
    return 0 if $refine_has_no_terms;
    my $available_record_filter = $available_only ? $self->_available_items_filter_sql('r') : q{};
    my $derived_record_filter = $self->_derived_record_filter_sql( $dbh, 'r', $derived_limits, 'derived_count' );
    my $facet_name_sql  = defined $facet_name  && length $facet_name  ? $dbh->quote($facet_name)  : undef;
    my $facet_value_sql = defined $facet_value && length $facet_value ? $dbh->quote($facet_value) : undef;

    my $sql = qq{
        SELECT COUNT(DISTINCT r.biblionumber)
        FROM nm2db_records r
        $eligible_record_join
        JOIN nm2db_fields f
            ON f.record_id = r.id
        JOIN nm2db_subfields s
            ON s.field_id = f.id
        WHERE r.type = 'biblio'
          $refine_record_filter
          $available_record_filter
          $derived_record_filter
          AND MATCH(s.value) AGAINST($search IN boolean MODE)
    };

    if ( defined $facet_name_sql && defined $facet_value_sql ) {
        $sql .= qq{
          AND EXISTS (
              SELECT 1
              FROM nm2db_keyword_search_facet_values sf2
              WHERE sf2.record_id = r.id
                AND sf2.name = $facet_name_sql
                AND sf2.value = $facet_value_sql
          )
        };
    }

    my ($count) = $dbh->selectrow_array($sql);
    return 0 + ( $count // 0 );
}

sub search_facets {
    my ( $self, $keyword, $facet_name, $facet_value, $options ) = @_;

    $options ||= {};
    my $refine = $self->_normalized_search_option( $options->{refine} );
    my $available_only = $options->{available_only} ? 1 : 0;
    my $derived_limits = $self->_normalized_derived_limits( $options->{derived_limits} );
    my $has_keyword = defined $keyword && $keyword =~ /\S/ ? 1 : 0;
    return [] unless $has_keyword || $self->_has_record_filters( $facet_name, $facet_value, $refine, $available_only, $derived_limits );

    my $dbh = C4::Context->dbh;
    return $self->_facets_for_filtered_records( $dbh, $facet_name, $facet_value, $refine, $available_only, $derived_limits )
        unless $has_keyword;

    my $exact_hits = $self->_should_use_exact_title_shortcut($keyword)
        ? $self->_exact_suggestion_hits( $dbh, $keyword )
        : [];
    if ( @{$exact_hits} ) {
        $exact_hits = $self->_filter_hits_by_facet( $dbh, $exact_hits, $facet_name, $facet_value );
        $exact_hits = $self->_filter_hits_by_derived_limits( $dbh, $exact_hits, $derived_limits );
        $exact_hits = $self->_filter_hits_by_refine( $dbh, $exact_hits, $refine );
        $exact_hits = $self->_filter_hits_by_availability( $dbh, $exact_hits, $available_only );
        return $self->_facets_for_exact_hits( $dbh, $exact_hits );
    }

    my $plain_terms = $self->_opac_like_index_terms( $dbh, $keyword );
    return [] if defined $plain_terms && !@{$plain_terms};
    my $boolean_search = $self->_opac_like_boolean_query( $keyword, $plain_terms );
    my $search = $dbh->quote($boolean_search);
    my $eligible_record_join = $self->_opac_like_eligible_record_join_sql( $dbh, 'r', $plain_terms, $search );
    my ( $refine_record_filter, $refine_has_no_terms ) = $self->_record_fulltext_filter_sql( $dbh, 'r', $refine, 'refine' );
    return [] if $refine_has_no_terms;
    my $available_record_filter = $available_only ? $self->_available_items_filter_sql('r') : q{};
    my $derived_record_filter = $self->_derived_record_filter_sql( $dbh, 'r', $derived_limits, 'derived_facets' );
    my $facet_name_sql  = defined $facet_name  && length $facet_name  ? $dbh->quote($facet_name)  : undef;
    my $facet_value_sql = defined $facet_value && length $facet_value ? $dbh->quote($facet_value) : undef;
    my $facet_max_count = int( C4::Context->preference('FacetMaxCount') // 20 );
    $facet_max_count = 1 if $facet_max_count < 1;
    $facet_max_count = 100 if $facet_max_count > 100;
    my $sql = qq{
        SELECT
            fv.name,
            COALESCE(sf.label, fv.name) AS label,
            fv.value,
            COUNT(DISTINCT fv.biblionumber) AS count
        FROM (
            SELECT DISTINCT r.id, r.biblionumber
            FROM nm2db_records r
            $eligible_record_join
            JOIN nm2db_fields f
                ON f.record_id = r.id
            JOIN nm2db_subfields s
                ON s.field_id = f.id
            WHERE r.type = 'biblio'
              $refine_record_filter
              $available_record_filter
              $derived_record_filter
              AND MATCH(s.value) AGAINST($search IN boolean MODE)
        ) hit
        JOIN nm2db_keyword_search_facet_values fv
            ON fv.record_id = hit.id
        LEFT JOIN search_field sf
            ON sf.name COLLATE utf8mb4_general_ci = fv.name
        WHERE 1 = 1
    };

    if ( defined $facet_name_sql && defined $facet_value_sql ) {
        $sql .= qq{
          AND EXISTS (
              SELECT 1
              FROM nm2db_keyword_search_facet_values sf2
              WHERE sf2.record_id = hit.id
                AND sf2.name = $facet_name_sql
                AND sf2.value = $facet_value_sql
          )
        };
    }

    $sql .= qq{
        GROUP BY fv.name, label, fv.value
    };
    $sql = qq{
        SELECT name, label, value, count
        FROM (
            SELECT
                grouped.*,
                ROW_NUMBER() OVER (
                    PARTITION BY grouped.name
                    ORDER BY grouped.count DESC, grouped.value
                ) AS facet_rank
            FROM (
                $sql
            ) grouped
        ) ranked
        WHERE facet_rank <= $facet_max_count
        ORDER BY name, count DESC, value
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute();
    my $rows = $sth->fetchall_arrayref({});

    return $self->_group_facet_rows($rows);
}

sub _group_facet_rows {
    my ( $self, $rows ) = @_;

    my @facets;
    my %pos;
    for my $row ( @{$rows} ) {
        my $name = $row->{name} // q{};
        next unless length $name;
        if ( !exists $pos{$name} ) {
            $pos{$name} = scalar @facets;
            push @facets, { name => $name, label => $row->{label} || $name, values => [] };
        }
        push @{ $facets[ $pos{$name} ]->{values} }, {
            value => defined $row->{value} ? $row->{value} : q{},
            count => 0 + ( $row->{count} // 0 ),
        };
    }

    return \@facets;
}

sub search_suggestions {
    my ( $self, $term, $limit ) = @_;

    $term //= q{};
    $term =~ s/^\s+|\s+\z//g;
    return [] unless length $term >= 2;

    $limit ||= 10;
    $limit = 50 if $limit > 50;

    my $dbh = C4::Context->dbh;
    my $contains_pattern = $self->_escaped_like_pattern( $term, 'contains' );
    my $prefix_pattern = $self->_escaped_like_pattern( $term, 'prefix' );
    my $rows = $dbh->selectall_arrayref(
        q{
            SELECT
                tag,
                code,
                value,
                MIN(biblionumber) AS biblionumber,
                COUNT(DISTINCT biblionumber) AS count,
                CASE WHEN value LIKE ? ESCAPE '=' THEN 0 ELSE 1 END AS match_rank
            FROM nm2db_keyword_search_suggestions
            WHERE value LIKE ? ESCAPE '='
            GROUP BY tag, code, value
            ORDER BY match_rank, count DESC, value
            LIMIT ?
        },
        { Slice => {} },
        $prefix_pattern,
        $contains_pattern,
        $limit
    );

    return [
        map {
            my $entry = {
                field => $_->{tag} . '$' . $_->{code},
                tag   => $_->{tag},
                code  => $_->{code},
                value => $_->{value},
                count => 0 + ( $_->{count} // 0 ),
            };
            $entry->{biblionumber} = 0 + $_->{biblionumber}
                if $entry->{count} == 1 && defined $_->{biblionumber};
            $entry;
        } @{$rows}
    ];
}

sub _exact_suggestion_hits {
    my ( $self, $dbh, $keyword ) = @_;

    $keyword //= q{};
    $keyword =~ s/^\s+|\s+\z//g;
    return [] unless length $keyword;

    return $dbh->selectall_arrayref(
        q{
            SELECT DISTINCT
                r.id AS record_id,
                r.biblionumber,
                sug.tag,
                sug.code,
                sug.value
            FROM nm2db_keyword_search_suggestions sug
            JOIN nm2db_records r
                ON r.type = 'biblio'
               AND r.biblionumber = sug.biblionumber
            WHERE sug.value = ?
            ORDER BY r.biblionumber
        },
        { Slice => {} },
        $keyword
    );
}

sub _should_use_exact_title_shortcut {
    my ( $self, $keyword ) = @_;

    $keyword //= q{};
    $keyword =~ s/^\s+|\s+\z//g;
    return 0 unless length $keyword >= 40;

    my @terms = ( $keyword =~ /([\p{Alnum}_]+)/g );
    return @terms >= 5 ? 1 : 0;
}

sub _normalized_search_option {
    my ( $self, $value ) = @_;

    $value //= q{};
    $value =~ s/^\s+|\s+\z//g;
    $value =~ s/\s+/ /g;

    return $value;
}

sub derived_limit_from_koha_limit {
    my ( $self, $limit ) = @_;

    return unless defined $limit && length $limit;
    $limit =~ s/\A\s+|\s+\z//g;

    if ( $limit =~ /\A([^:=]+),ge[=:]\s*([0-9]{4})\s+and\s+([^:=]+),le[=:]\s*([0-9]{4})\z/i ) {
        my ( $from_name, $from, $to_name, $to ) = ( $1, $2, $3, $4 );
        my $from_canonical = $self->canonical_derived_index($from_name);
        my $to_canonical   = $self->canonical_derived_index($to_name);
        return
            unless $from_canonical
            && $to_canonical
            && $from_canonical eq $to_canonical;

        return {
            name => $from_canonical,
            from => 0 + $from,
            to   => 0 + $to,
        };
    }

    my ( $index, $value ) = $limit =~ /\A([^:=]+)[=:](.+)\z/;
    return unless defined $index && defined $value;

    my $name = $self->canonical_derived_index($index);
    return unless $name;

    my ( $from, $to ) = $self->_parse_year_operand($value);
    return unless defined $from || defined $to;

    return {
        name => $name,
        from => $from,
        to   => $to,
    };
}

sub canonical_derived_index {
    my ( $self, $index ) = @_;

    return unless defined $index && length $index;
    $index =~ s/\A\s+|\s+\z//g;
    $index =~ s/,(?:st-numeric|st-year)\z//i;
    $index = lc $index;

    my %aliases = (
        'date-of-publication' => 'date-of-publication',
        pubdate               => 'date-of-publication',
        yr                    => 'date-of-publication',
    );

    return $aliases{$index};
}

sub _parse_year_operand {
    my ( $self, $value ) = @_;

    return unless defined $value;
    $value =~ s/\A\s+|\s+\z//g;
    $value =~ s/\A"(.*)"\z/$1/;

    if ( $value =~ /\A([0-9]{4})\z/ ) {
        my $year = 0 + $1;
        return ( $year, $year );
    }

    if ( $value =~ /\A([0-9]{4})?\s*-\s*([0-9]{4})?\z/ ) {
        my $from = defined $1 && length $1 ? 0 + $1 : undef;
        my $to   = defined $2 && length $2 ? 0 + $2 : undef;
        return ( $from, $to ) if defined $from || defined $to;
    }

    return;
}

sub _normalized_derived_limits {
    my ( $self, $limits ) = @_;

    return [] unless ref $limits eq 'ARRAY';

    my @normalized;
    for my $limit ( @{$limits} ) {
        next unless ref $limit eq 'HASH';
        my $name = $self->canonical_derived_index( $limit->{name} );
        next unless $name;

        my $from = defined $limit->{from} && $limit->{from} =~ /\A[0-9]{4}\z/
            ? 0 + $limit->{from}
            : undef;
        my $to = defined $limit->{to} && $limit->{to} =~ /\A[0-9]{4}\z/
            ? 0 + $limit->{to}
            : undef;
        next unless defined $from || defined $to;

        push @normalized, {
            name => $name,
            from => $from,
            to   => $to,
        };
    }

    return \@normalized;
}

sub _has_record_filters {
    my ( $self, $facet_name, $facet_value, $refine, $available_only, $derived_limits ) = @_;

    return 1
        if defined $facet_name
        && length $facet_name
        && defined $facet_value
        && length $facet_value;
    return 1 if defined $refine && $refine =~ /\S/;
    return 1 if $available_only;
    return 1 if $derived_limits && @{$derived_limits};

    return 0;
}

sub _filtered_record_rows {
    my ( $self, $dbh, $facet_name, $facet_value, $options, $refine, $available_only, $derived_limits ) = @_;

    my ( $refine_record_filter, $refine_has_no_terms ) = $self->_record_fulltext_filter_sql( $dbh, 'r', $refine, 'filter_refine' );
    return [] if $refine_has_no_terms;

    my $available_record_filter = $available_only ? $self->_available_items_filter_sql('r') : q{};
    my $derived_record_filter   = $self->_derived_record_filter_sql( $dbh, 'r', $derived_limits, 'filter_derived' );
    my $facet_record_filter     = $self->_facet_record_filter_sql( $dbh, 'r', $facet_name, $facet_value );
    my $metadata_select = $options->{include_xml} ? 'bm.metadata AS xml' : 'NULL AS xml';
    my $metadata_join = $options->{include_xml}
        ? q{
        LEFT JOIN biblio_metadata bm
            ON bm.biblionumber = r.biblionumber
           AND bm.format = 'marcxml'
        }
        : q{};
    my $metadata_group = $options->{include_xml} ? ', bm.metadata' : q{};
    my $limit = int( $options->{limit} // 200 );
    $limit = 1 if $limit < 1;
    $limit = 1000 if $limit > 1000;
    my $offset = int( $options->{offset} // 0 );
    $offset = 0 if $offset < 0;

    my $sql = qq{
        SELECT
            r.biblionumber,
            0 AS weight_sum,
            0 AS relevance,
            COALESCE(GROUP_CONCAT(DISTINCT dv.name ORDER BY dv.name SEPARATOR ', '), 'record') AS tag,
            COALESCE(
                GROUP_CONCAT(DISTINCT CONCAT(dv.name, ': ', dv.value) ORDER BY dv.name, dv.value SEPARATOR '\n'),
                CONCAT('biblionumber: ', r.biblionumber)
            ) AS value,
            $metadata_select
        FROM nm2db_records r
        $metadata_join
        LEFT JOIN nm2db_keyword_search_derived_values dv
            ON dv.record_id = r.id
        WHERE r.type = 'biblio'
          $refine_record_filter
          $available_record_filter
          $derived_record_filter
          $facet_record_filter
        GROUP BY r.biblionumber $metadata_group
        ORDER BY r.biblionumber
        LIMIT $limit OFFSET $offset
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute();

    return $sth->fetchall_arrayref({});
}

sub _count_filtered_records {
    my ( $self, $dbh, $facet_name, $facet_value, $refine, $available_only, $derived_limits ) = @_;

    my ( $refine_record_filter, $refine_has_no_terms ) = $self->_record_fulltext_filter_sql( $dbh, 'r', $refine, 'count_filter_refine' );
    return 0 if $refine_has_no_terms;

    my $available_record_filter = $available_only ? $self->_available_items_filter_sql('r') : q{};
    my $derived_record_filter   = $self->_derived_record_filter_sql( $dbh, 'r', $derived_limits, 'count_filter_derived' );
    my $facet_record_filter     = $self->_facet_record_filter_sql( $dbh, 'r', $facet_name, $facet_value );

    my ($count) = $dbh->selectrow_array(qq{
        SELECT COUNT(DISTINCT r.biblionumber)
        FROM nm2db_records r
        WHERE r.type = 'biblio'
          $refine_record_filter
          $available_record_filter
          $derived_record_filter
          $facet_record_filter
    });

    return 0 + ( $count // 0 );
}

sub _facets_for_filtered_records {
    my ( $self, $dbh, $facet_name, $facet_value, $refine, $available_only, $derived_limits ) = @_;

    my ( $refine_record_filter, $refine_has_no_terms ) = $self->_record_fulltext_filter_sql( $dbh, 'r', $refine, 'facet_filter_refine' );
    return [] if $refine_has_no_terms;

    my $available_record_filter = $available_only ? $self->_available_items_filter_sql('r') : q{};
    my $derived_record_filter   = $self->_derived_record_filter_sql( $dbh, 'r', $derived_limits, 'facet_filter_derived' );
    my $facet_record_filter     = $self->_facet_record_filter_sql( $dbh, 'r', $facet_name, $facet_value );
    my $facet_max_count = int( C4::Context->preference('FacetMaxCount') // 20 );
    $facet_max_count = 1 if $facet_max_count < 1;
    $facet_max_count = 100 if $facet_max_count > 100;

    my $sql = qq{
        SELECT
            fv.name,
            COALESCE(sf.label, fv.name) AS label,
            fv.value,
            COUNT(DISTINCT fv.biblionumber) AS count
        FROM (
            SELECT DISTINCT r.id, r.biblionumber
            FROM nm2db_records r
            WHERE r.type = 'biblio'
              $refine_record_filter
              $available_record_filter
              $derived_record_filter
              $facet_record_filter
        ) hit
        JOIN nm2db_keyword_search_facet_values fv
            ON fv.record_id = hit.id
        LEFT JOIN search_field sf
            ON sf.name COLLATE utf8mb4_general_ci = fv.name
        GROUP BY fv.name, label, fv.value
    };

    $sql = qq{
        SELECT name, label, value, count
        FROM (
            SELECT
                grouped.*,
                ROW_NUMBER() OVER (
                    PARTITION BY grouped.name
                    ORDER BY grouped.count DESC, grouped.value
                ) AS facet_rank
            FROM (
                $sql
            ) grouped
        ) ranked
        WHERE facet_rank <= $facet_max_count
        ORDER BY name, count DESC, value
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute();
    my $rows = $sth->fetchall_arrayref({});

    return $self->_group_facet_rows($rows);
}

sub _record_fulltext_filter_sql {
    my ( $self, $dbh, $record_alias, $keyword, $alias ) = @_;

    return ( q{}, 0 ) unless defined $keyword && $keyword =~ /\S/;

    my $plain_terms = $self->_opac_like_index_terms( $dbh, $keyword );
    return ( q{}, 1 ) if defined $plain_terms && !@{$plain_terms};

    my $search = $dbh->quote( $self->_opac_like_boolean_query( $keyword, $plain_terms ) );
    my $record_table_alias = $alias . '_r';
    my $field_table_alias  = $alias . '_f';
    my $subfield_alias     = $alias . '_s';
    my @having;
    if ( $plain_terms && @{$plain_terms} > 1 ) {
        for my $term ( @{$plain_terms} ) {
            my $term_search = $dbh->quote( '+' . $term . '*' );
            push @having, qq{MAX(MATCH($subfield_alias.value) AGAINST($term_search IN boolean MODE) > 0) = 1};
        }
    }
    my $having_sql = @having ? 'HAVING ' . join( ' AND ', @having ) : q{};

    return (
        qq{
              AND EXISTS (
                  SELECT 1
                  FROM nm2db_records $record_table_alias
                  JOIN nm2db_fields $field_table_alias
                      ON $field_table_alias.record_id = $record_table_alias.id
                  JOIN nm2db_subfields $subfield_alias
                      ON $subfield_alias.field_id = $field_table_alias.id
                  WHERE $record_table_alias.type = 'biblio'
                    AND $record_table_alias.id = $record_alias.id
                    AND MATCH($subfield_alias.value) AGAINST($search IN boolean MODE)
                  GROUP BY $record_table_alias.id
                  $having_sql
              )
        },
        0
    );
}

sub _facet_record_filter_sql {
    my ( $self, $dbh, $record_alias, $facet_name, $facet_value ) = @_;

    return q{}
        unless defined $facet_name && length $facet_name
        && defined $facet_value && length $facet_value;

    my $facet_name_sql  = $dbh->quote($facet_name);
    my $facet_value_sql = $dbh->quote($facet_value);

    return qq{
              AND EXISTS (
                  SELECT 1
                  FROM nm2db_keyword_search_facet_values facet_filter
                  WHERE facet_filter.record_id = $record_alias.id
                    AND facet_filter.name = $facet_name_sql
                    AND facet_filter.value = $facet_value_sql
              )
    };
}

sub _derived_record_filter_sql {
    my ( $self, $dbh, $record_alias, $derived_limits, $alias ) = @_;

    return q{} unless $derived_limits && @{$derived_limits};

    my @filters;
    for my $i ( 0 .. $#{$derived_limits} ) {
        my $limit = $derived_limits->[$i];
        next unless ref $limit eq 'HASH';
        my $name = $limit->{name};
        next unless defined $name && length $name;
        next unless defined $limit->{from} || defined $limit->{to};

        my $derived_alias = $alias . '_' . $i;
        my $name_sql = $dbh->quote($name);
        my @range_sql;
        push @range_sql, $derived_alias . '.numeric_value >= ' . int( $limit->{from} )
            if defined $limit->{from};
        push @range_sql, $derived_alias . '.numeric_value <= ' . int( $limit->{to} )
            if defined $limit->{to};
        my $range_sql = join( "\n                    AND ", @range_sql );

        push @filters, qq{
              EXISTS (
                  SELECT 1
                  FROM nm2db_keyword_search_derived_values $derived_alias
                  WHERE $derived_alias.record_id = $record_alias.id
                    AND $derived_alias.name = $name_sql
                    AND $derived_alias.numeric_value IS NOT NULL
                    AND $range_sql
              )
        };
    }

    return q{} unless @filters;

    return "\n              AND " . join( "\n              AND ", @filters );
}

sub _available_items_filter_sql {
    my ( $self, $record_alias ) = @_;

    my $item_condition = $self->_available_items_condition_sql('available_i');

    return qq{
              AND EXISTS (
                  SELECT 1
                  FROM items available_i
                  WHERE available_i.biblionumber = $record_alias.biblionumber
                    AND $item_condition
              )
    };
}

sub _available_items_condition_sql {
    my ( $self, $item_alias ) = @_;

    return qq{
                    $item_alias.onloan IS NULL
                    AND COALESCE($item_alias.itemlost, 0) = 0
                    AND COALESCE($item_alias.withdrawn, 0) = 0
                    AND COALESCE($item_alias.notforloan, 0) = 0
    };
}

sub _filter_hits_by_facet {
    my ( $self, $dbh, $hits, $facet_name, $facet_value ) = @_;

    return $hits
        unless defined $facet_name && length $facet_name
        && defined $facet_value && length $facet_value;
    return [] unless @{$hits};

    my @record_ids = map { $_->{record_id} } @{$hits};
    my $placeholders = join q{,}, ('?') x @record_ids;
    my $rows = $dbh->selectall_arrayref(
        qq{
            SELECT DISTINCT record_id
            FROM nm2db_keyword_search_facet_values
            WHERE record_id IN ($placeholders)
              AND name = ?
              AND value = ?
        },
        { Slice => {} },
        @record_ids,
        $facet_name,
        $facet_value
    );
    my %keep = map { $_->{record_id} => 1 } @{$rows};

    return [ grep { $keep{ $_->{record_id} } } @{$hits} ];
}

sub _filter_hits_by_derived_limits {
    my ( $self, $dbh, $hits, $derived_limits ) = @_;

    return $hits unless $derived_limits && @{$derived_limits};
    return [] unless @{$hits};

    my @kept_hits = @{$hits};
    for my $limit ( @{$derived_limits} ) {
        next unless ref $limit eq 'HASH';
        next unless defined $limit->{name} && length $limit->{name};
        next unless defined $limit->{from} || defined $limit->{to};
        return [] unless @kept_hits;

        my @record_ids = map { $_->{record_id} } @kept_hits;
        my $placeholders = join q{,}, ('?') x @record_ids;
        my @where = (
            "record_id IN ($placeholders)",
            'name = ?',
            'numeric_value IS NOT NULL',
        );
        my @bind = ( @record_ids, $limit->{name} );
        if ( defined $limit->{from} ) {
            push @where, 'numeric_value >= ?';
            push @bind, 0 + $limit->{from};
        }
        if ( defined $limit->{to} ) {
            push @where, 'numeric_value <= ?';
            push @bind, 0 + $limit->{to};
        }

        my $rows = $dbh->selectall_arrayref(
            'SELECT DISTINCT record_id FROM nm2db_keyword_search_derived_values WHERE ' . join( ' AND ', @where ),
            { Slice => {} },
            @bind
        );
        my %keep = map { $_->{record_id} => 1 } @{$rows};
        @kept_hits = grep { $keep{ $_->{record_id} } } @kept_hits;
    }

    return \@kept_hits;
}

sub _filter_hits_by_refine {
    my ( $self, $dbh, $hits, $refine ) = @_;

    return $hits unless defined $refine && $refine =~ /\S/;
    return [] unless @{$hits};

    my $plain_terms = $self->_opac_like_index_terms( $dbh, $refine );
    return [] if defined $plain_terms && !@{$plain_terms};

    my @record_ids = map { $_->{record_id} } @{$hits};
    my $placeholders = join q{,}, ('?') x @record_ids;
    my $search = $dbh->quote( $self->_opac_like_boolean_query( $refine, $plain_terms ) );
    my @having;
    if ( $plain_terms && @{$plain_terms} > 1 ) {
        for my $term ( @{$plain_terms} ) {
            my $term_search = $dbh->quote( '+' . $term . '*' );
            push @having, qq{MAX(MATCH(refine_s.value) AGAINST($term_search IN boolean MODE) > 0) = 1};
        }
    }
    my $having_sql = @having ? 'HAVING ' . join( ' AND ', @having ) : q{};
    my $rows = $dbh->selectall_arrayref(
        qq{
            SELECT refine_r.id AS record_id
            FROM nm2db_records refine_r
            JOIN nm2db_fields refine_f
                ON refine_f.record_id = refine_r.id
            JOIN nm2db_subfields refine_s
                ON refine_s.field_id = refine_f.id
            WHERE refine_r.type = 'biblio'
              AND refine_r.id IN ($placeholders)
              AND MATCH(refine_s.value) AGAINST($search IN boolean MODE)
            GROUP BY refine_r.id
            $having_sql
        },
        { Slice => {} },
        @record_ids
    );
    my %keep = map { $_->{record_id} => 1 } @{$rows};

    return [ grep { $keep{ $_->{record_id} } } @{$hits} ];
}

sub _filter_hits_by_availability {
    my ( $self, $dbh, $hits, $available_only ) = @_;

    return $hits unless $available_only;
    return [] unless @{$hits};

    my @biblionumbers = map { $_->{biblionumber} } @{$hits};
    my $placeholders = join q{,}, ('?') x @biblionumbers;
    my $item_condition = $self->_available_items_condition_sql('available_i');
    my $rows = $dbh->selectall_arrayref(
        qq{
            SELECT DISTINCT available_i.biblionumber
            FROM items available_i
            WHERE available_i.biblionumber IN ($placeholders)
              AND $item_condition
        },
        { Slice => {} },
        @biblionumbers
    );
    my %keep = map { $_->{biblionumber} => 1 } @{$rows};

    return [ grep { $keep{ $_->{biblionumber} } } @{$hits} ];
}

sub _exact_suggestion_result_rows {
    my ( $self, $dbh, $hits, $options ) = @_;

    return [] unless @{$hits};

    my $offset = int( $options->{offset} // 0 );
    $offset = 0 if $offset < 0;
    my $limit = int( $options->{limit} // scalar @{$hits} );
    $limit = 1 if $limit < 1;
    $limit = 1000 if $limit > 1000;
    my @paged_hits = $offset > $#{$hits}
        ? ()
        : @{$hits}[ $offset .. $#{$hits} ];
    splice @paged_hits, $limit if @paged_hits > $limit;
    $hits = \@paged_hits;
    return [] unless @{$hits};

    my %metadata;
    if ( $options->{include_xml} ) {
        my @biblionumbers = map { $_->{biblionumber} } @{$hits};
        my $placeholders = join q{,}, ('?') x @biblionumbers;
        my $rows = $dbh->selectall_arrayref(
            qq{
                SELECT biblionumber, metadata
                FROM biblio_metadata
                WHERE format = 'marcxml'
                  AND biblionumber IN ($placeholders)
            },
            { Slice => {} },
            @biblionumbers
        );
        %metadata = map { $_->{biblionumber} => $_->{metadata} } @{$rows};
    }

    return [
        map {
            my $field = $_->{tag} . $_->{code};
            +{
                biblionumber => 0 + $_->{biblionumber},
                tag          => $field,
                value        => $field . ' [exact title]: ' . $_->{value},
                xml          => $metadata{ $_->{biblionumber} } // q{},
            }
        } @{$hits}
    ];
}

sub _facets_for_exact_hits {
    my ( $self, $dbh, $hits ) = @_;

    return [] unless @{$hits};

    my @record_ids = map { $_->{record_id} } @{$hits};
    my $placeholders = join q{,}, ('?') x @record_ids;
    my $facet_max_count = int( C4::Context->preference('FacetMaxCount') // 20 );
    $facet_max_count = 1 if $facet_max_count < 1;
    $facet_max_count = 100 if $facet_max_count > 100;
    my $rows = $dbh->selectall_arrayref(
        qq{
            SELECT name, label, value, count
            FROM (
                SELECT
                    grouped.*,
                    ROW_NUMBER() OVER (
                        PARTITION BY grouped.name
                        ORDER BY grouped.count DESC, grouped.value
                    ) AS facet_rank
                FROM (
                    SELECT
                        fv.name,
                        COALESCE(sf.label, fv.name) AS label,
                        fv.value,
                        COUNT(DISTINCT fv.biblionumber) AS count
                    FROM nm2db_keyword_search_facet_values fv
                    LEFT JOIN search_field sf
                        ON sf.name COLLATE utf8mb4_general_ci = fv.name
                    WHERE fv.record_id IN ($placeholders)
                    GROUP BY fv.name, label, fv.value
                ) grouped
            ) ranked
            WHERE facet_rank <= $facet_max_count
            ORDER BY name, count DESC, value
        },
        { Slice => {} },
        @record_ids
    );

    return $self->_group_facet_rows($rows);
}

sub _opac_like_boolean_query {
    my ( $self, $keyword, $plain_terms ) = @_;

    $keyword //= q{};
    $keyword =~ s/^\s+|\s+\z//g;
    return $keyword unless length $keyword;

    return @$plain_terms == 1
        ? '+' . $plain_terms->[0] . '*'
        : join q{ }, map { $_ . '*' } @{$plain_terms}
        if $plain_terms;

    return $keyword;
}

sub _create_keyword_lookup_tables {
    my ( $self, $dbh ) = @_;

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS nm2db_keyword_search_weights (
            tag char(6) NOT NULL,
            code char(1) NOT NULL DEFAULT '',
            weight decimal(5,2) NOT NULL DEFAULT 0,
            PRIMARY KEY (tag, code)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
    });

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS nm2db_keyword_search_facets (
            tag char(6) NOT NULL,
            code char(1) NOT NULL DEFAULT '',
            name varchar(191) NOT NULL,
            PRIMARY KEY (tag, code, name),
            KEY nm2db_keyword_facets_name_idx (name, tag, code)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
    });

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS nm2db_keyword_search_facet_values (
            id int(11) NOT NULL AUTO_INCREMENT,
            record_id int(11) NOT NULL,
            biblionumber int(11) DEFAULT NULL,
            name varchar(191) NOT NULL,
            value text NOT NULL,
            PRIMARY KEY (id),
            KEY nm2db_keyword_fv_record_idx (record_id, name, value(191)),
            KEY nm2db_keyword_fv_name_value_idx (name, value(191), record_id),
            KEY nm2db_keyword_fv_biblio_idx (biblionumber)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
    });

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS nm2db_keyword_search_suggestions (
            id int(11) NOT NULL AUTO_INCREMENT,
            tag char(6) NOT NULL,
            code char(1) NOT NULL DEFAULT '',
            biblionumber int(11) DEFAULT NULL,
            value varchar(1024) NOT NULL,
            PRIMARY KEY (id),
            KEY nm2db_keyword_suggest_value_idx (value(191)),
            KEY nm2db_keyword_suggest_field_value_idx (tag, code, value(191)),
            KEY nm2db_keyword_suggest_biblio_idx (biblionumber)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
    });

    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS nm2db_keyword_search_derived_values (
            id int(11) NOT NULL AUTO_INCREMENT,
            record_id int(11) NOT NULL,
            biblionumber int(11) DEFAULT NULL,
            name varchar(191) NOT NULL,
            value varchar(191) NOT NULL,
            numeric_value int(11) DEFAULT NULL,
            source varchar(191) NOT NULL,
            PRIMARY KEY (id),
            UNIQUE KEY nm2db_keyword_dv_unique_idx (record_id, name, value),
            KEY nm2db_keyword_dv_name_num_idx (name, numeric_value, record_id),
            KEY nm2db_keyword_dv_record_idx (record_id, name, numeric_value),
            KEY nm2db_keyword_dv_biblio_idx (biblionumber)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
    });
}

sub _refresh_keyword_lookup_tables {
    my ( $self, $dbh ) = @_;

    $dbh->do(q{TRUNCATE TABLE nm2db_keyword_search_weights});
    $dbh->do(q{
        INSERT INTO nm2db_keyword_search_weights (tag, code, weight)
        SELECT
            tc.tag,
            tc.code,
            COALESCE(MAX(CASE WHEN smtf.search = 1 THEN sf.weight END), 0) AS weight
        FROM (
            SELECT DISTINCT f.tag, COALESCE(s.code, '') AS code
            FROM nm2db_fields f
            JOIN nm2db_subfields s
                ON s.field_id = f.id
        ) tc
        JOIN search_marc_map smm
            ON smm.marc_type = 'marc21'
           AND smm.index_name = 'biblios'
           AND LEFT(smm.marc_field, 3) = tc.tag
           AND (
                CHAR_LENGTH(smm.marc_field) = 3
                OR LOCATE(tc.code, SUBSTRING(smm.marc_field, 4)) > 0
           )
        JOIN search_marc_to_field smtf
            ON smtf.search_marc_map_id = smm.id
        JOIN search_field sf
            ON sf.id = smtf.search_field_id
        WHERE smtf.search = 1
        GROUP BY tc.tag, tc.code
    });

    $dbh->do(q{TRUNCATE TABLE nm2db_keyword_search_facets});
    $dbh->do(q{
        INSERT IGNORE INTO nm2db_keyword_search_facets (tag, code, name)
        SELECT
            LEFT(smm.marc_field, 3) AS tag,
            CASE
                WHEN CHAR_LENGTH(smm.marc_field) > 3 THEN SUBSTRING(smm.marc_field, 4, 1)
                ELSE ''
            END AS code,
            sf.name
        FROM search_marc_map smm
        JOIN search_marc_to_field smtf
            ON smtf.search_marc_map_id = smm.id
           AND smtf.facet = 1
        JOIN search_field sf
            ON sf.id = smtf.search_field_id
        WHERE smm.marc_type = 'marc21'
          AND smm.index_name = 'biblios'
          AND smm.marc_field REGEXP '^[0-9]{3}[0-9A-Za-z]?$'
    });

    $dbh->do(q{TRUNCATE TABLE nm2db_keyword_search_facet_values});
    $dbh->do(q{
        INSERT INTO nm2db_keyword_search_facet_values (record_id, biblionumber, name, value)
        SELECT DISTINCT
            r.id,
            r.biblionumber,
            sf.name,
            s.value
        FROM nm2db_records r
        JOIN nm2db_fields f
            ON f.record_id = r.id
        JOIN nm2db_subfields s
            ON s.field_id = f.id
        JOIN nm2db_keyword_search_facets sf
            ON sf.tag = f.tag
           AND sf.code = COALESCE(s.code, '')
        WHERE r.type = 'biblio'
          AND s.value IS NOT NULL
          AND TRIM(s.value) <> ''
    });

    $self->_refresh_item_facet_values($dbh);
    $self->_refresh_derived_index_values($dbh);
    $self->_refresh_suggestions($dbh);
}

sub _refresh_derived_index_values {
    my ( $self, $dbh ) = @_;

    $dbh->do(q{TRUNCATE TABLE nm2db_keyword_search_derived_values});

    $dbh->do(q{
        INSERT IGNORE INTO nm2db_keyword_search_derived_values (
            record_id,
            biblionumber,
            name,
            value,
            numeric_value,
            source
        )
        SELECT DISTINCT
            r.id,
            r.biblionumber,
            'date-of-publication',
            SUBSTRING(s.value, 8, 4) AS publication_year,
            CAST(SUBSTRING(s.value, 8, 4) AS UNSIGNED) AS numeric_publication_year,
            '008/7-10'
        FROM nm2db_records r
        JOIN nm2db_fields f
            ON f.record_id = r.id
           AND f.tag = '008'
        JOIN nm2db_subfields s
            ON s.field_id = f.id
           AND COALESCE(s.code, '') = ''
        WHERE r.type = 'biblio'
          AND SUBSTRING(s.value, 8, 4) REGEXP '^[0-9]{4}$'
    });
}

sub _refresh_item_facet_values {
    my ( $self, $dbh ) = @_;

    my %item_columns = (
        '952a' => 'homebranch',
        '952b' => 'holdingbranch',
        '952c' => 'location',
        '9528' => 'ccode',
        '952y' => 'itype',
    );

    for my $marc_field ( sort keys %item_columns ) {
        my ( $tag, $code ) = ( substr( $marc_field, 0, 3 ), substr( $marc_field, 3, 1 ) );
        my $column = $item_columns{$marc_field};

        $dbh->do(
            qq{
                INSERT INTO nm2db_keyword_search_facet_values (record_id, biblionumber, name, value)
                SELECT DISTINCT
                    r.id,
                    i.biblionumber,
                    f.name,
                    i.$column
                FROM nm2db_keyword_search_facets f
                JOIN nm2db_records r
                    ON r.type = 'biblio'
                JOIN items i
                    ON i.biblionumber = r.biblionumber
                WHERE f.tag = ?
                  AND f.code = ?
                  AND i.$column IS NOT NULL
                  AND i.$column <> ''
            },
            undef,
            $tag,
            $code
        );
    }
}

sub _refresh_suggestions {
    my ( $self, $dbh ) = @_;

    my @fields = $self->_suggestion_fields;
    return unless @fields;

    my @conditions;
    my @bind;
    for my $field (@fields) {
        push @conditions, q{(f.tag = ? AND COALESCE(s.code, '') = ?)};
        push @bind, $field->{tag}, $field->{code};
    }

    $dbh->do(q{TRUNCATE TABLE nm2db_keyword_search_suggestions});

    my $sql = q{
        INSERT INTO nm2db_keyword_search_suggestions (tag, code, biblionumber, value)
        SELECT DISTINCT
            f.tag,
            COALESCE(s.code, '') AS code,
            r.biblionumber,
            LEFT(TRIM(s.value), 1024) AS value
        FROM nm2db_records r
        JOIN nm2db_fields f
            ON f.record_id = r.id
        JOIN nm2db_subfields s
            ON s.field_id = f.id
        WHERE r.type = 'biblio'
          AND s.value IS NOT NULL
          AND TRIM(s.value) <> ''
          AND (} . join( ' OR ', @conditions ) . q{)
    };

    $dbh->do( $sql, undef, @bind );
}

sub _suggestion_fields {
    return (
        { tag => '245', code => 'a' },
    );
}

sub _ensure_index {
    my ( $self, $dbh, $table, $index, $sql ) = @_;

    return if $self->_index_exists( $dbh, $table, $index );

    $dbh->do($sql);
}

sub _ensure_search_field {
    my ( $self, $dbh, $name, $label, $facet_order ) = @_;

    $dbh->do(
        q{
            INSERT INTO search_field (name, label, type, facet_order, staff_client, opac)
            VALUES (?, ?, 'string', ?, 1, 1)
            ON DUPLICATE KEY UPDATE
                label = VALUES(label),
                type = IF(type = '', VALUES(type), type),
                facet_order = VALUES(facet_order)
        },
        undef,
        $name,
        $label,
        $facet_order
    );

    my ($id) = $dbh->selectrow_array(
        q{SELECT id FROM search_field WHERE name = ?},
        undef,
        $name
    );

    return $id;
}

sub _ensure_search_marc_map {
    my ( $self, $dbh, $marc_type, $marc_field ) = @_;

    $dbh->do(
        q{
            INSERT IGNORE INTO search_marc_map (index_name, marc_type, marc_field)
            VALUES ('biblios', ?, ?)
        },
        undef,
        $marc_type,
        $marc_field
    );

    my ($id) = $dbh->selectrow_array(
        q{
            SELECT id
            FROM search_marc_map
            WHERE index_name = 'biblios'
              AND marc_type = ?
              AND marc_field = ?
        },
        undef,
        $marc_type,
        $marc_field
    );

    return $id;
}

sub _enable_search_marc_facet {
    my ( $self, $dbh, $search_marc_map_id, $search_field_id ) = @_;

    $dbh->do(
        q{
            INSERT INTO search_marc_to_field (
                search,
                filter,
                search_marc_map_id,
                search_field_id,
                facet,
                suggestible,
                sort
            )
            VALUES (1, '', ?, ?, 1, 0, 1)
            ON DUPLICATE KEY UPDATE facet = 1
        },
        undef,
        $search_marc_map_id,
        $search_field_id
    );
}

sub _facet_marc_fields {
    my ( $self, $tags ) = @_;

    my @marc_fields;
    for my $tag ( @{$tags || []} ) {
        my $tag_num = substr( $tag, 0, 3 );
        my $codes = substr( $tag, 3 );

        if ( length $codes ) {
            push @marc_fields, map { $tag_num . $_ } split //, $codes;
        } else {
            push @marc_fields, $tag_num;
        }
    }

    my %seen;
    return grep { !$seen{$_}++ } @marc_fields;
}

sub _drop_index_if_exists {
    my ( $self, $dbh, $table, $index ) = @_;

    return unless $self->_table_exists( $dbh, $table );
    return unless $self->_index_exists( $dbh, $table, $index );

    $dbh->do("ALTER TABLE `$table` DROP INDEX `$index`");
}

sub _index_exists {
    my ( $self, $dbh, $table, $index ) = @_;

    return 0 unless $self->_table_exists( $dbh, $table );

    my ($exists) = $dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM information_schema.statistics
            WHERE table_schema = DATABASE()
              AND table_name = ?
              AND index_name = ?
        },
        undef,
        $table,
        $index
    );

    return $exists ? 1 : 0;
}

sub _table_exists {
    my ( $self, $dbh, $table ) = @_;

    my ($exists) = $dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE table_schema = DATABASE()
              AND table_name = ?
        },
        undef,
        $table
    );

    return $exists ? 1 : 0;
}

sub _opac_like_plain_terms {
    my ( $self, $keyword ) = @_;

    $keyword //= q{};
    $keyword =~ s/^\s+|\s+\z//g;
    return unless length $keyword;

    return
        if $keyword =~ /["*+\-~<>]/;

    my @terms = ( $keyword =~ /([\p{Alnum}_]+)/g );
    return unless @terms;

    return \@terms;
}

sub _escaped_like_pattern {
    my ( $self, $term, $mode ) = @_;

    $term //= q{};
    $term =~ s/([=%_])/=$1/g;

    return $mode && $mode eq 'prefix'
        ? $term . '%'
        : '%' . $term . '%';
}

sub _opac_like_index_terms {
    my ( $self, $dbh, $keyword ) = @_;

    my $terms = $self->_opac_like_plain_terms($keyword);
    return unless $terms;

    my $min_token_size = $self->_fulltext_min_token_size($dbh);
    my $stopwords = $self->_fulltext_stopwords($dbh);
    my @index_terms = grep {
        length($_) >= $min_token_size && !$stopwords->{ lc $_ }
    } @{$terms};

    return \@index_terms;
}

sub _opac_like_eligible_record_join_sql {
    my ( $self, $dbh, $record_alias, $plain_terms, $search ) = @_;

    return q{} unless $plain_terms && @{$plain_terms} > 1;

    my @having;
    for my $term ( @{$plain_terms} ) {
        my $term_search = $dbh->quote( '+' . $term . '*' );
        push @having, qq{MAX(MATCH(term_s.value) AGAINST($term_search IN boolean MODE) > 0) = 1};
    }

    return q{} unless @having;

    return qq{
            JOIN (
                SELECT term_r.id
                FROM nm2db_records term_r
                JOIN nm2db_fields term_f
                    ON term_f.record_id = term_r.id
                JOIN nm2db_subfields term_s
                    ON term_s.field_id = term_f.id
                WHERE term_r.type = 'biblio'
                  AND MATCH(term_s.value) AGAINST($search IN boolean MODE)
                GROUP BY term_r.id
                HAVING } . join( ' AND ', @having ) . qq{
            ) eligible_hit
                ON eligible_hit.id = $record_alias.id
    };
}

sub _fulltext_min_token_size {
    my ( $self, $dbh ) = @_;

    return $FULLTEXT_MIN_TOKEN_SIZE if defined $FULLTEXT_MIN_TOKEN_SIZE;

    my ($min_token_size) = eval {
        $dbh->selectrow_array(q{SELECT @@innodb_ft_min_token_size});
    };
    $FULLTEXT_MIN_TOKEN_SIZE = $min_token_size || 3;

    return $FULLTEXT_MIN_TOKEN_SIZE;
}

sub _fulltext_stopwords {
    my ( $self, $dbh ) = @_;

    return $FULLTEXT_STOPWORDS if $FULLTEXT_STOPWORDS;

    my ($enabled) = eval {
        $dbh->selectrow_array(q{SELECT @@innodb_ft_enable_stopword});
    };
    if ( defined $enabled && $enabled =~ /^(?:0|OFF)$/i ) {
        $FULLTEXT_STOPWORDS = {};
        return $FULLTEXT_STOPWORDS;
    }

    my $rows = eval {
        $dbh->selectcol_arrayref(q{
            SELECT value
            FROM INFORMATION_SCHEMA.INNODB_FT_DEFAULT_STOPWORD
        });
    } || [];
    $FULLTEXT_STOPWORDS = { map { lc($_) => 1 } @{$rows} };

    return $FULLTEXT_STOPWORDS;
}

sub add_rendered_html {
    my ( $self, $rows, $type ) = @_;

    $type ||= 'opac';

    foreach my $row ( @{$rows} ) {
        $row->{rendered_html} = q{};
        next unless $row->{biblionumber};
        $row->{rendered_html} = $self->render_biblio_html( $row->{biblionumber}, $type );
    }

    return $rows;
}

sub render_biblio_html {
    my ( $self, $biblionumber, $type, $lang_query ) = @_;

    return q{} unless $biblionumber;

    my $xsl;
    my $htdocs;
    if ( $type && $type eq 'intranet' ) {
        $xsl = 'MARC21slim2intranetResults.xsl';
        $htdocs = C4::Context->config('intrahtdocs');
    } else {
        $xsl = 'MARC21slim2OPACResults.xsl';
        $htdocs = C4::Context->config('opachtdocs');
    }

    my ( $theme, $lang ) = C4::Templates::themelanguage( $htdocs, $xsl, $type );
    $lang = $lang_query if $lang_query;
    $xsl = "$htdocs/$theme/$lang/xslt/$xsl";

    my $xml = GetXmlBiblio($biblionumber);
    return q{} unless $xml;

    my $itemsxml = q{};
    my $biblio = Koha::Biblios->find($biblionumber);
    if ($biblio) {
        $itemsxml = C4::XSLT::buildKohaItemsNamespace( $biblionumber, [], $biblio->items );
    }

    my $sysxml = C4::XSLT::get_xslt_sysprefs();
    $xml =~ s{</record>}{$itemsxml$sysxml</record>};

    return C4::XSLT::engine->transform( $xml, $xsl ) || q{};
}

1;

__END__



select marc_field, facet, filter, search   from search_marc_map smm join search_marc_to_field smf on smm.id = smf.search_marc_map_id  where smm.marc_type = 'marc21' and smm.index_name = 'biblios'
