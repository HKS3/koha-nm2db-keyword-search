package Koha::Plugin::HKS3::NM2DBKeywordSearch;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use CGI;
use C4::Auth qw(get_template_and_user);
use C4::Context;
use Cwd qw(abs_path);
use Mojo::JSON qw(decode_json);

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

sub tool {
    my ($self) = @_;
    my $cgi = $self->{cgi};

    my $template = $self->get_template({ file => 'tool.tt' });
    my $keyword  = defined $cgi->param('keyword') ? $cgi->param('keyword') : q{};
    my $results  = $self->search_records($keyword);

    $template->param(
        keyword         => $keyword,
        results         => $results,
        opac_search_url => $self->opac_search_url,
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
    my ( $self, $keyword ) = @_;

    my $template = $self->get_opac_template;

    $template->param(
        keyword               => $keyword,
        results               => $self->search_records($keyword),
        intranet_plugin_url   => $self->intranet_tool_url,
    );

    return $template->output;
}

sub opac_search_url {
    return '/api/v1/contrib/nm2db_keyword_search/search';
}

sub intranet_tool_url {
    return '/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::HKS3::NM2DBKeywordSearch&method=tool';
}

sub search_records {
    my ( $self, $keyword ) = @_;

    return [] unless defined $keyword && $keyword =~ /\S/;

    my $dbh = C4::Context->dbh;
    my $search = $dbh->quote( '%' . $keyword . '%' );
    my $sql = qq{
        SELECT biblionumber, tag, value
        FROM nm2db_v_record
        WHERE value LIKE $search
        ORDER BY biblionumber, tag, value
        LIMIT 200
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute();

    return $sth->fetchall_arrayref({});
}

1;
