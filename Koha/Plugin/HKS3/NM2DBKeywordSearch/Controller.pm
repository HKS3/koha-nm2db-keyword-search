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
    my $plugin = Koha::Plugin::HKS3::NM2DBKeywordSearch->new();
    my $raw_results = $plugin->search_records( $keyword, $facet_name, $facet_value );
    $raw_results = $plugin->add_rendered_html( $raw_results, $type );
    my $facets = $plugin->search_facets( $keyword, $facet_name, $facet_value );
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

    return $c->render(
        status  => 200,
        openapi => {
            keyword     => $keyword,
            facet_name  => $facet_name,
            facet_value => $facet_value,
            count       => scalar @results,
            results     => \@results,
            facets      => $facets,
        },
    );
}

sub page {
    my ($c) = @_;

    my $keyword = $c->param('keyword') // q{};
    my $facet_name = $c->param('facet_name') // q{};
    my $facet_value = $c->param('facet_value') // q{};
    my $plugin = Koha::Plugin::HKS3::NM2DBKeywordSearch->new();
    my $html = $plugin->render_opac_page( $keyword, $facet_name, $facet_value );

    $c->res->headers->content_type('text/html; charset=utf-8');
    return $c->render(
        status => 200,
        text   => $html,
    );
}

1;
