package Koha::Plugin::HKS3::NM2DBKeywordSearch::WordIndex;

use Modern::Perl;
use C4::Context;

my $TABLE = 'nm2db_keyword_search_words';
my $CLASS = 'Koha::Plugin::HKS3::NM2DBKeywordSearch';

sub ready {
    my ($class) = @_;
    return C4::Context->dbh->selectrow_array(
        q{SELECT plugin_value FROM plugin_data WHERE plugin_class = ? AND plugin_key = 'word_index_ready'},
        undef, $CLASS
    ) ? 1 : 0;
}

sub create_table {
    C4::Context->dbh->do(qq{
        CREATE TABLE IF NOT EXISTS $TABLE (
            term varchar(255) NOT NULL,
            biblionumber int(11) NOT NULL,
            weight decimal(14,3) NOT NULL DEFAULT 0,
            PRIMARY KEY (term, biblionumber),
            KEY nm2db_keyword_words_biblio_idx (biblionumber),
            CONSTRAINT nm2db_keyword_words_biblio_fk FOREIGN KEY (biblionumber)
                REFERENCES biblio (biblionumber) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    });
}

sub tokens {
    my ( $class, $value ) = @_;
    my %seen;
    return [ grep { !$seen{$_}++ } map { substr( lc($_), 0, 255 ) }
        ( ( $value // q{} ) =~ /([\p{Alnum}_]+)/g ) ];
}

sub _weights {
    return C4::Context->dbh->selectall_hashref(
        q{SELECT CONCAT(tag, code) AS field, weight FROM nm2db_keyword_search_weights}, 'field'
    );
}

sub _insert_words {
    my ( $class, $biblionumber, $words ) = @_;
    my @bind = map { ( $_, $biblionumber, $words->{$_} ) } sort keys %{$words};
    $class->_insert_rows(\@bind);
}

sub _insert_rows {
    my ( $class, $values ) = @_;
    my $dbh = C4::Context->dbh;
    while ( @{$values} ) {
        my @bind = splice @{$values}, 0, 3000;
        $dbh->do(
            "INSERT INTO $TABLE (term, biblionumber, weight) VALUES "
                . join( ',', ('(?, ?, ?)') x ( @bind / 3 ) )
                . ' ON DUPLICATE KEY UPDATE weight = weight + VALUES(weight)',
            undef, @bind
        );
    }
}

sub refresh {
    my ( $class, $progress ) = @_;
    my $dbh = C4::Context->dbh;
    $class->create_table;
    die "Word index refresh requires its own transaction\n" unless $dbh->{AutoCommit};
    my $weights = $class->_weights;
    my ( $last_id, $records ) = ( 0, 0 );
    $dbh->begin_work;
    eval {
        # Only replace this plugin-owned, reproducible cache.
        $dbh->do("DELETE FROM $TABLE");
        while (1) {
            my $ids = $dbh->selectcol_arrayref(
                q{SELECT id FROM nm2db_records WHERE type = 'biblio' AND id > ? ORDER BY id LIMIT 500},
                undef, $last_id
            );
            last unless @{$ids};
            my $end_id = $ids->[-1];
            my $rows = $dbh->selectall_arrayref(
                q{
                    SELECT r.biblionumber, f.tag, COALESCE(s.code, '') AS code, s.value
                    FROM nm2db_records r
                    JOIN nm2db_fields f ON f.record_id = r.id
                    JOIN nm2db_subfields s ON s.field_id = f.id
                    WHERE r.type = 'biblio' AND r.id > ? AND r.id <= ?
                }, { Slice => {} }, $last_id, $end_id
            );
            my %words;
            for my $row ( @{$rows} ) {
                my $weight = $weights->{ $row->{tag} . $row->{code} }->{weight} // 0;
                for my $term ( @{ $class->tokens( $row->{value} ) } ) {
                    $words{ $row->{biblionumber} }->{$term} += $weight;
                }
            }
            my @values;
            for my $id ( sort { $a <=> $b } keys %words ) {
                push @values, map { ( $_, $id, $words{$id}->{$_} ) } sort keys %{ $words{$id} };
            }
            $class->_insert_rows(\@values);
            $records += @{$ids};
            $last_id = $end_id;
            $progress->($records) if $progress;
        }
        $dbh->do(
            q{REPLACE INTO plugin_data (plugin_class, plugin_key, plugin_value) VALUES (?, 'word_index_ready', '1')},
            undef, $CLASS
        );
        $dbh->commit;
        1;
    } or do {
        my $error = $@;
        $dbh->rollback;
        die $error;
    };
    return $records;
}

sub update_record {
    my ( $class, $biblionumber, $record ) = @_;
    return unless $class->ready;
    my $dbh = C4::Context->dbh;
    my $weights = $class->_weights;
    my %words;
    my @values = ( [ 'leader', q{}, $record->leader ] );
    for my $field ( $record->fields ) {
        push @values, $field->is_control_field
            ? [ $field->tag, q{}, $field->data ]
            : map { [ $field->tag, @{$_} ] } $field->subfields;
    }
    for my $value (@values) {
        my ( $tag, $code, $text ) = @{$value};
        my $weight = $weights->{ $tag . $code }->{weight} // 0;
        $words{$_} += $weight for @{ $class->tokens($text) };
    }
    my $own_transaction = $dbh->{AutoCommit};
    $dbh->begin_work if $own_transaction;
    eval {
        $dbh->do("DELETE FROM $TABLE WHERE biblionumber = ?", undef, $biblionumber);
        $class->_insert_words( $biblionumber, \%words );
        $dbh->commit if $own_transaction;
        1;
    } or do {
        my $error = $@;
        $dbh->rollback if $own_transaction;
        die $error;
    };
}

sub search {
    my ( $class, $terms ) = @_;
    my $dbh = C4::Context->dbh;
    my @matches;
    for my $term ( @{$terms} ) {
        $term =~ s/([=%_])/=$1/g;
        push @matches, $dbh->selectall_arrayref(
            qq{SELECT biblionumber, SUM(weight) AS weight_sum FROM $TABLE
                WHERE term LIKE ? ESCAPE '=' GROUP BY biblionumber},
            { Slice => {} }, $term . '%'
        );
    }
    my %hits = map { $_->{biblionumber} => { %{$_} } } @{ shift @matches || [] };
    for my $matches (@matches) {
        my %match = map { $_->{biblionumber} => $_->{weight_sum} } @{$matches};
        for my $id ( keys %hits ) {
            if ( exists $match{$id} ) {
                $hits{$id}->{weight_sum} += $match{$id};
            } else {
                delete $hits{$id};
            }
        }
    }
    return [] unless %hits;
    my @ids = keys %hits;
    my $records = $dbh->selectall_arrayref(
        'SELECT id AS record_id, biblionumber FROM nm2db_records WHERE type = '
            . $dbh->quote('biblio') . ' AND biblionumber IN (' . join( ',', ('?') x @ids ) . ')',
        { Slice => {} }, @ids
    );
    return [ sort { $b->{weight_sum} <=> $a->{weight_sum} || $a->{biblionumber} <=> $b->{biblionumber} }
        map { +{ %{$_}, weight_sum => $hits{ $_->{biblionumber} }->{weight_sum} } } @{$records} ];
}

1;
