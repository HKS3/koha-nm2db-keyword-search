# NM2DB Keyword Search

Koha plugin that adds:

- an intranet search page at `plugins/run.pl?class=Koha::Plugin::HKS3::NM2DBKeywordSearch&method=tool`
- an OPAC search page at `/api/v1/contrib/nm2db_keyword_search/public/search`

Both pages search `nm2db_v_record` using:

```sql
SELECT biblionumber, tag, value
FROM nm2db_v_record
WHERE value LIKE '%keyword%'
ORDER BY biblionumber, tag, value
LIMIT 200
```

The actual implementation uses a prepared statement with a bound `LIKE` parameter.
