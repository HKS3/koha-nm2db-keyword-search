package Koha::Plugin::HKS3::NM2DBKeywordSearch::Controller;

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use Koha::Plugin::HKS3::NM2DBKeywordSearch;

sub search {
    my ($c) = @_;

    $c->openapi->valid_input or return;

    my $keyword = $c->validation->param('keyword') // q{};
    my $plugin = Koha::Plugin::HKS3::NM2DBKeywordSearch->new();
    my $raw_results = $plugin->search_records($keyword);
    my @results = map {
        +{
            biblionumber => 0 + $_->{biblionumber},
            tag          => defined $_->{tag} ? "$_->{tag}" : q{},
            value        => defined $_->{value} ? "$_->{value}" : q{},
        }
    } grep {
        defined $_->{biblionumber}
    } @{$raw_results};

    return $c->render(
        status  => 200,
        openapi => {
            keyword => $keyword,
            count   => scalar @results,
            results => \@results,
        },
    );
}

1;
