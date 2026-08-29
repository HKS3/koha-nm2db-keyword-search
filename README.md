# NM2DB Keyword Search

Koha plugin that adds:

- an intranet search page at `plugins/run.pl?class=Koha::Plugin::HKS3::NM2DBKeywordSearch&method=tool`
- an OPAC search page at `/api/v1/contrib/nm2db_keyword_search/page`

it uses and relies on 

https://github.com/HKS3/koha-normalize-marc2db

## Search behavior

Plain keyword searches are expanded to MySQL boolean prefix terms, for example
`book` becomes `+book*`. For multi-word searches, each prefix must match
somewhere in the record. The result query searches all normalized bibliographic
subfields and still uses Koha search-field weights where a MARC mapping exists.
This is intended to match Koha OPAC's simple keyword path, which uses
right-truncated keyword searches.

For plain multi-word searches the plugin drops terms that InnoDB fulltext would
ignore anyway, using the database `innodb_ft_min_token_size` and default
stopword list. This keeps title searches such as
`Programme of the jornadas de taxonomía vegetal III` from spending time on
unindexable words like `of`, `the`, and `de`.

Before falling back to fulltext, long submitted title-like terms are checked
against the typeahead title cache. An exact cached `245$a` title match returns
that bibliographic record directly, which keeps selected typeahead titles fast
even when they are very long. Short exact title values such as `Blumen` still
run as normal keyword searches, so they can find all keyword matches.

## Performance cache

The plugin install hook creates the fulltext and join indexes used by the
keyword queries. It also builds small plugin-owned lookup/cache tables:

- `nm2db_keyword_search_weights`
- `nm2db_keyword_search_facets`
- `nm2db_keyword_search_facet_values`
- `nm2db_keyword_search_suggestions`

During install/cache refresh the plugin also rewrites MARC21 bibliographic
`search_marc_to_field.facet` flags to the Zebra facet set from
`C4::Koha::getFacets`: topics, places, uniform titles, authors, series, item
types, locations, collections, and the configured library facet. The nm2db facet
cache is populated from those flagged mappings; item-level `952` facets are read
from Koha's `items` table because they are not present in the normalized
bibliographic MARC tables.

After reloading the normalized MARC tables, refresh these caches:

```sh
/kohadevbox/plugins/koha-nm2db-keyword-search/script/refresh_keyword_search_cache.pl
```

The `/api/v1/contrib/nm2db_keyword_search/search` endpoint also accepts
`include=results`, `include=facets`, or `include=all`. Result sets can be
narrowed with `facet_name`/`facet_value`, `refine` for an additional
search-within-results term, and `available_only=1` for records with at least
one item that is not on loan, lost, withdrawn, or not-for-loan. The static
search pages use `include` to request results and facets concurrently instead
of doing both in one server request.

The intranet plugin page renders results with Koha's DataTables/Responsive
assets. Its search input performs live AJAX searches and uses
`/api/v1/contrib/nm2db_keyword_search/suggestions` for typeahead suggestions.
The typeahead matches contained text, with prefix matches ordered first. The
suggestion cache is built from a defined MARC field list, currently `245$a`.

The plugin also exposes `opac_js` and `intranet_js` hooks. When Koha's plugin
method registry is current, those hooks add the same title typeahead to normal
OPAC and staff catalogue search forms that submit to `opac-search.pl` or
`catalogue/search.pl`. A unique suggestion carries its `biblionumber`, so an
explicit browser typeahead replacement can jump directly to the record detail
page. Submitting the form still performs a normal keyword search.

After adding or changing hook methods in a mounted plugin checkout, refresh
Koha's plugin method registry:

```sh
perl -MKoha::Plugins -E 'Koha::Plugins->new->InstallPlugins({ include => [ q{Koha::Plugin::HKS3::NM2DBKeywordSearch} ] })'
```

## Tests

Run the integration comparison test inside a KTD instance with the plugin mounted:

```sh
prove -v /kohadevbox/plugins/koha-nm2db-keyword-search/t/nm2db_vs_koha_search.t
```

The test compares this plugin's normalized-MARC keyword search with Koha's normal
catalog keyword search and fails with the differing biblionumbers if the result
sets diverge.

## Search comparison script

Run a list of searches and print differences between the plugin and Koha:

```sh
/kohadevbox/plugins/koha-nm2db-keyword-search/script/compare_searches.pl \
  /kohadevbox/plugins/koha-nm2db-keyword-search/examples/searches.tsv
```

Search files are tab-separated. Use one column for a shared term, two columns
for `plugin query<TAB>Koha query`, or three columns for
`label<TAB>plugin query<TAB>Koha query`.

Run the broader comparison fixture in summary mode:

```sh
/kohadevbox/plugins/koha-nm2db-keyword-search/script/compare_searches.pl \
  --brief --koha-mode opac-code --plugin-mode direct \
  /kohadevbox/plugins/koha-nm2db-keyword-search/examples/wide_searches.tsv
```

By default the script compares the plugin API route with Koha's OPAC web search
route. Use `--koha-mode opac-code` to compare against Koha's OPAC search code
without HTTP, `--koha-mode intranet-code` to compare against the staff
`catalogue/search.pl` code path without HTTP, or
`--koha-mode direct --plugin-mode direct` for the older
`C4::Search::SimpleSearch` comparison. `--koha-mode intranet-web` fetches the
staff search page over HTTP and logs in with `KOHA_INTRANET_USER` and
`KOHA_INTRANET_PASSWORD` or the matching command-line options.

Run one Koha OPAC web search from the command line:

```sh
/kohadevbox/plugins/koha-nm2db-keyword-search/script/koha_web_search.pl book
```

Run one Koha intranet catalogue web search from the command line:

```sh
/kohadevbox/plugins/koha-nm2db-keyword-search/script/koha_web_search.pl \
  --interface intranet book
```

Run the same OPAC or intranet search code path without the web interface:

```sh
/kohadevbox/plugins/koha-nm2db-keyword-search/script/koha_opac_code_search.pl book
/kohadevbox/plugins/koha-nm2db-keyword-search/script/koha_opac_code_search.pl \
  --interface intranet book
```

## Web comparison page

Open the browser comparison tool in KTD:

```text
http://nm2db2511.localhost:8080/api/v1/contrib/nm2db_keyword_search/static/ui/compare.html
```

The page runs the plugin API route and Koha's OPAC search page through HTTP,
then compares the biblionumbers parsed from both web responses. For the Koha
column use a plain term, CCL such as `kw=perl`, `ccl:kw=perl`, or URL
parameters such as `idx=kw&q=perl`.
