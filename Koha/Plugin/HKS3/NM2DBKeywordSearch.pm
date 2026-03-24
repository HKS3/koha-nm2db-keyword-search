package Koha::Plugin::HKS3::NM2DBKeywordSearch;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use CGI;
use C4::Auth qw(get_template_and_user);
use C4::Biblio qw(GetXmlBiblio);
use C4::Context;
use C4::Templates;
use C4::XSLT;
use Cwd qw(abs_path);
use Mojo::JSON qw(decode_json);
use Koha::Biblios;

our $VERSION = '0.01';

our $metadata = {
    name            => 'NM2DB Keyword Search',
    author          => 'OpenAI Codex',
    description     => 'Adds OPAC and intranet keyword search pages for nm2db_v_record',
    namespace       => 'nm2db_keyword_search',
    date_authored   => '2026-03-24',
    date_updated    => '2026-03-24',
    minimum_version => '23.11',
    maximum_version => undef,
    version         => $VERSION,
};

sub new {
    my ( $class, $args ) = @_;

    $args->{metadata}         = $metadata;
    $args->{metadata}{class}  = $class;

    my $self = $class->SUPER::new($args);
    $self->{cgi} = CGI->new();

    return $self;
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
        api_search_url => $self->opac_search_url,
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
    my ( $self, $keyword, $facet_name, $facet_value ) = @_;

    my $template = $self->get_opac_template;
    my $results = $self->search_records( $keyword, $facet_name, $facet_value );
    $results = $self->add_rendered_html( $results, 'opac' );
    my $facets = $self->search_facets( $keyword, $facet_name, $facet_value );

    $template->param(
        keyword               => $keyword,
        results               => $results,
        facets                => $facets,
        selected_facet_name   => $facet_name,
        selected_facet_value  => $facet_value,
        intranet_plugin_url   => $self->intranet_tool_url,
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

sub intranet_tool_url {
    return '/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::HKS3::NM2DBKeywordSearch&method=tool';
}

sub search_records {
    my ( $self, $keyword, $facet_name, $facet_value ) = @_;

    return [] unless defined $keyword && $keyword =~ /\S/;

    my $dbh = C4::Context->dbh;
    my $search = $dbh->quote($keyword);
    my $facet_name_sql  = defined $facet_name  && length $facet_name  ? $dbh->quote($facet_name)  : undef;
    my $facet_value_sql = defined $facet_value && length $facet_value ? $dbh->quote($facet_value) : undef;
    my $sql = qq{
        SELECT
            r.biblionumber,
            MAX(MATCH(s.value) AGAINST($search IN NATURAL LANGUAGE MODE)) AS relevance,
            GROUP_CONCAT( DISTINCT f.tag ORDER BY f.tag SEPARATOR ', ' ) AS tag,
            GROUP_CONCAT( DISTINCT CONCAT(f.tag, ': ', s.value) ORDER BY f.tag, s.value SEPARATOR '\n' ) AS value,
            bm.metadata AS xml
        FROM nm2db_records r
        JOIN nm2db_fields f
            ON f.record_id = r.id
        JOIN nm2db_subfields s
            ON s.field_id = f.id
        JOIN search_marc_map smm
            ON smm.marc_type = 'marc21'
           AND smm.index_name = 'biblios'
           AND LEFT(smm.marc_field, 3) = f.tag
           AND (
                CHAR_LENGTH(smm.marc_field) = 3
                OR LOCATE(s.code, SUBSTRING(smm.marc_field, 4)) > 0
           )
        JOIN search_marc_to_field smtf
            ON smtf.search_marc_map_id = smm.id
        JOIN search_field sf
            ON sf.id = smtf.search_field_id
        LEFT JOIN biblio_metadata bm
            ON bm.biblionumber = r.biblionumber
           AND bm.format = 'marcxml'
        WHERE r.type = 'biblio'
          AND smtf.search = 1
          AND MATCH(s.value) AGAINST($search IN NATURAL LANGUAGE MODE)
    };

    if ( defined $facet_name_sql && defined $facet_value_sql ) {
        $sql .= qq{
          AND EXISTS (
              SELECT 1
              FROM nm2db_fields ff
              JOIN nm2db_subfields ss
                  ON ss.field_id = ff.id
              JOIN search_marc_map smm2
                  ON smm2.marc_type = 'marc21'
                 AND smm2.index_name = 'biblios'
                 AND LEFT(smm2.marc_field, 3) = ff.tag
                 AND (
                      CHAR_LENGTH(smm2.marc_field) = 3
                      OR LOCATE(ss.code, SUBSTRING(smm2.marc_field, 4)) > 0
                 )
              JOIN search_marc_to_field smtf2
                  ON smtf2.search_marc_map_id = smm2.id
              JOIN search_field sf2
                  ON sf2.id = smtf2.search_field_id
              WHERE ff.record_id = r.id
                AND smtf2.facet = 1
                AND sf2.name = $facet_name_sql
                AND ss.value = $facet_value_sql
          )
        };
    }

    $sql .= qq{
        GROUP BY r.biblionumber, bm.metadata
        ORDER BY relevance DESC, r.biblionumber
        LIMIT 200
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute();

    return $sth->fetchall_arrayref({});
}

sub search_facets {
    my ( $self, $keyword, $facet_name, $facet_value ) = @_;

    return [] unless defined $keyword && $keyword =~ /\S/;

    my $dbh = C4::Context->dbh;
    my $search = $dbh->quote($keyword);
    my $facet_name_sql  = defined $facet_name  && length $facet_name  ? $dbh->quote($facet_name)  : undef;
    my $facet_value_sql = defined $facet_value && length $facet_value ? $dbh->quote($facet_value) : undef;
    my $sql = qq{
        SELECT
            sf.name,
            s.value,
            COUNT(DISTINCT r.biblionumber) AS count
        FROM nm2db_records r
        JOIN nm2db_fields f
            ON f.record_id = r.id
        JOIN nm2db_subfields s
            ON s.field_id = f.id
        JOIN search_marc_map smm
            ON smm.marc_type = 'marc21'
           AND smm.index_name = 'biblios'
           AND LEFT(smm.marc_field, 3) = f.tag
           AND (
                CHAR_LENGTH(smm.marc_field) = 3
                OR LOCATE(s.code, SUBSTRING(smm.marc_field, 4)) > 0
           )
        JOIN search_marc_to_field smtf
            ON smtf.search_marc_map_id = smm.id
        JOIN search_field sf
            ON sf.id = smtf.search_field_id
        WHERE r.type = 'biblio'
          AND smtf.facet = 1
          AND MATCH(s.value) AGAINST($search IN NATURAL LANGUAGE MODE)
    };

    if ( defined $facet_name_sql && defined $facet_value_sql ) {
        $sql .= qq{
          AND EXISTS (
              SELECT 1
              FROM nm2db_fields ff
              JOIN nm2db_subfields ss
                  ON ss.field_id = ff.id
              JOIN search_marc_map smm2
                  ON smm2.marc_type = 'marc21'
                 AND smm2.index_name = 'biblios'
                 AND LEFT(smm2.marc_field, 3) = ff.tag
                 AND (
                      CHAR_LENGTH(smm2.marc_field) = 3
                      OR LOCATE(ss.code, SUBSTRING(smm2.marc_field, 4)) > 0
                 )
              JOIN search_marc_to_field smtf2
                  ON smtf2.search_marc_map_id = smm2.id
              JOIN search_field sf2
                  ON sf2.id = smtf2.search_field_id
              WHERE ff.record_id = r.id
                AND smtf2.facet = 1
                AND sf2.name = $facet_name_sql
                AND ss.value = $facet_value_sql
          )
        };
    }

    $sql .= qq{
        GROUP BY sf.name, s.value
        ORDER BY sf.name, count DESC, s.value
        LIMIT 500
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute();
    my $rows = $sth->fetchall_arrayref({});

    my @facets;
    my %pos;
    for my $row ( @{$rows} ) {
        my $name = $row->{name} // q{};
        next unless length $name;
        if ( !exists $pos{$name} ) {
            $pos{$name} = scalar @facets;
            push @facets, { name => $name, values => [] };
        }
        push @{ $facets[ $pos{$name} ]->{values} }, {
            value => defined $row->{value} ? $row->{value} : q{},
            count => 0 + ( $row->{count} // 0 ),
        };
    }

    return \@facets;
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
