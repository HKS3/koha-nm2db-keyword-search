package Koha::Plugin::HKS3::NM2DBKeywordSearch::Controller;

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use Koha::Plugin::HKS3::NM2DBKeywordSearch;

sub search {
    my ($c) = @_;

    $c->openapi->valid_input or return;

    my $keyword = $c->validation->param('keyword') // q{};
    my $type = $c->validation->param('type') || 'opac';
    my $facet_name = $c->validation->param('facet_name') // q{};
    my $facet_value = $c->validation->param('facet_value') // q{};
    my $refine = $c->validation->param('refine') // q{};
    my $available_only = _truthy_param( $c->validation->param('available_only') );
    my $include = $c->validation->param('include') || 'all';
    my $include_results = $include eq 'all' || $include eq 'results';
    my $include_facets = $include eq 'all' || $include eq 'facets';
    my $search_options = {
        refine         => $refine,
        available_only => $available_only,
    };
    my $plugin = Koha::Plugin::HKS3::NM2DBKeywordSearch->new();

    my $raw_results = [];
    if ($include_results) {
        $raw_results = $plugin->search_records( $keyword, $facet_name, $facet_value, $search_options );
        $raw_results = $plugin->add_rendered_html( $raw_results, $type );
    }

    my @results = map {
        +{
            biblionumber => 0 + $_->{biblionumber},
            tag          => defined $_->{tag} ? "$_->{tag}" : q{},
            value        => defined $_->{value} ? "$_->{value}" : q{},
            xml          => defined $_->{xml} ? "$_->{xml}" : q{},
            rendered_html => defined $_->{rendered_html} ? "$_->{rendered_html}" : q{},
        }
    } grep {
        defined $_->{biblionumber}
    } @{$raw_results};

    my $facets = $include_facets
        ? $plugin->search_facets( $keyword, $facet_name, $facet_value, $search_options )
        : [];

    return $c->render(
        status  => 200,
        openapi => {
            keyword        => $keyword,
            facet_name     => $facet_name,
            facet_value    => $facet_value,
            refine         => $refine,
            available_only => $available_only,
            include        => $include,
            count          => scalar @results,
            results        => \@results,
            facets         => $facets,
        },
    );
}

sub suggestions {
    my ($c) = @_;

    $c->openapi->valid_input or return;

    my $term = $c->validation->param('term') // q{};
    my $limit = $c->validation->param('limit') || 10;
    my $plugin = Koha::Plugin::HKS3::NM2DBKeywordSearch->new();
    my $suggestions = $plugin->search_suggestions( $term, $limit );

    return $c->render(
        status  => 200,
        openapi => {
            term        => $term,
            suggestions => $suggestions,
        },
    );
}

sub page {
    my ($c) = @_;

    my $keyword = $c->param('keyword') // q{};
    my $facet_name = $c->param('facet_name') // q{};
    my $facet_value = $c->param('facet_value') // q{};
    my $refine = $c->param('refine') // q{};
    my $available_only = _truthy_param( $c->param('available_only') );
    my $plugin = Koha::Plugin::HKS3::NM2DBKeywordSearch->new();
    my $html = $plugin->render_opac_page(
        $keyword,
        $facet_name,
        $facet_value,
        {
            refine         => $refine,
            available_only => $available_only,
        }
    );

    $c->res->headers->content_type('text/html; charset=utf-8');
    return $c->render(
        status => 200,
        text   => $html,
    );
}

sub _truthy_param {
    my ($value) = @_;

    return 0 unless defined $value;
    return $value =~ /^(?:1|true|on|yes)$/i ? 1 : 0;
}

1;
