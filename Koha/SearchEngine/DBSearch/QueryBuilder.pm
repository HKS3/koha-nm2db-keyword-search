package Koha::SearchEngine::DBSearch::QueryBuilder;

use Modern::Perl;

use base qw(Class::Accessor);

use URI::Escape qw(uri_escape_utf8);
use C4::AuthoritiesMarc;

sub new {
    my ( $class, $params ) = @_;

    return bless { index => $params->{index} }, $class;
}

sub index {
    my ($self) = @_;

    return $self->{index};
}

sub build_query_compat {
    my $self = shift;
    my ( $operators, $operands, $indexes, $limits, $sort_by, $scan, $lang, $params ) = @_;

    $operands ||= [];
    $indexes  ||= [];
    $limits   ||= [];

    my @terms = grep { defined && /\S/ } @{$operands};
    my $query = {
        dbsearch => {
            query    => join( q{ }, @terms ),
            operands => $operands,
            indexes  => $indexes,
            limits   => $limits,
            sort_by  => $sort_by || [],
            scan     => $scan ? 1 : 0,
        }
    };

    my @query_cgi;
    for my $i ( 0 .. $#terms ) {
        my $idx = $indexes->[$i] // 'kw';
        push @query_cgi, 'idx=' . uri_escape_utf8($idx);
        push @query_cgi, 'q=' . uri_escape_utf8( $terms[$i] );
    }

    my $limit_cgi = @{$limits}
        ? '&limit=' . join( '&limit=', map { uri_escape_utf8($_) } @{$limits} )
        : q{};
    my $query_desc = join( q{ }, @terms );

    return (
        undef,
        $query,
        $query_desc,
        join( q{&}, @query_cgi ),
        $query_desc,
        join( q{ and }, @{$limits} ),
        $limit_cgi,
        join( q{ and }, @{$limits} ),
        'dbsearch'
    );
}

sub build_authorities_query {
    shift;
    return {
        marclist     => $_[0],
        and_or       => $_[1],
        excluding    => $_[2],
        operator     => $_[3],
        value        => $_[4],
        authtypecode => $_[5],
        orderby      => $_[6],
    };
}

sub build_authorities_query_compat {
    build_authorities_query(@_);
}

sub clean_search_term {
    my ( $self, $term ) = @_;

    $term =~ s/"/\\"/g if defined $term;

    return $term;
}

1;
