package Koha::SearchEngine::DBSearch::Indexer;

use Modern::Perl;

use base qw(Class::Accessor);

sub new {
    my ( $class, $params ) = @_;

    return bless { index => $params->{index} }, $class;
}

sub index {
    my ($self) = @_;

    return $self->{index};
}

sub index_records {
    my ( $self, $record_numbers, $op, $server, $records ) = @_;

    require Koha::SearchEngine::Zebra::Indexer;
    my $zebra = Koha::SearchEngine::Zebra::Indexer->new( { index => $self->index } );
    return $zebra->index_records( $record_numbers, $op, $server, $records );
}

1;
