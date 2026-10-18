# NM2DB Keyword Search

Koha plugin that adds:

- an intranet cache-maintenance tool at `plugins/run.pl?class=Koha::Plugin::HKS3::NM2DBKeywordSearch&method=tool` (no search form)
- an OPAC search page at `/api/v1/contrib/nm2db_keyword_search/page`

it uses and relies on 

https://github.com/HKS3/koha-normalize-marc2db

## Version 0.1 (2026-10-18)

Fixes [issue #1](https://github.com/HKS3/koha-nm2db-keyword-search/issues/1)
in [2424331](https://github.com/HKS3/koha-nm2db-keyword-search/commit/24243313e58c7173f514d16e634529c00f309ff0):
plain searches for short words and MariaDB stopwords, including `go`, `who`
and `for`, now use an indexed word-prefix search instead of being discarded.
The index has no minimum word length or stopword exclusions. Matching is
reused within a request, only the requested result page is rendered, and
the total hit count is not artificially capped. Boolean/fulltext queries
retain MariaDB's existing restrictions; identical results to Zebra are not
guaranteed.

This version also adds MARC21 authority search with visible heading metadata
and correct first-page offsets, a protected background cache-refresh tool,
and DBSearch-only catalogue typeahead hooks. The plugin tool is maintenance
only; normal staff/OPAC searches and the standalone search pages remain.

When upgrading from 0.05, refresh Koha's plugin method registry, reload Plack
and restart the `long_tasks` worker, then build the new word index as described
under **Performance cache**, or use **Refresh search caches** in the plugin
tool. Deploying the new files alone does not build the index on an existing
installation. The full cache refresh also resets facet mappings as documented
below; original MARC, items and authorities are preserved.

## Search behavior

Plain keyword searches use a plugin-owned word index over all normalized
bibliographic subfields. Words are Unicode alphanumeric/underscore sequences,
lowercased and indexed with no minimum length or stopword exclusion. `go` finds
the standalone word `Go` and word prefixes such as `Goethe`, but not `Chicago`.
For multi-word queries, every word prefix must match somewhere in the record,
including short terms and stopwords; words need not be in the same subfield.
Koha's MARC search-field weights contribute to result ordering.

Matching IDs and weights are calculated once per plugin object/request and
reused for the hit count, result pages and facets. Only the requested page's
MARCXML and display subfields are loaded. There is no artificial hit-count cap;
the existing result-page limit (maximum 1,000 rows) does not cap the total.

Explicit Boolean/fulltext queries (quotes, `+`, `-`, `*`, etc.) retain the
MariaDB fulltext path and its token-size/stopword restrictions. If an existing
installation has not built the word index yet, the earlier fulltext/SQL
fallback remains active; build the word index to enable the fast plain path.

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
- `nm2db_keyword_search_words`

For an existing installation, build just the derived word index, without
changing MARC, items, authorities, mappings, MariaDB settings or its fulltext
index (inside `koha-shell kohadev`):

```sh
perl /kohadevbox/plugins/koha-nm2db-keyword-search/script/refresh_word_index.pl --confirm
```

The rebuild replaces only the plugin-owned word cache in a transaction. Its
readiness flag is set after a successful build. Re-run after a bulk reload of
normalized MARC or changes to search-field weights. The `after_biblio_action`
hook updates the index on ordinary catalogue creation/modification, reading
MARC directly so normalization-hook order does not matter. Deleted biblios
remove their word entries through a foreign key. Refresh Koha's plugin method
registry after deploying the new hook, then reload Plack.

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

Alternatively, open **NM2DB Keyword Search → Run tool** in the staff plugin
list and click **Refresh search caches**. This POST/CSRF-protected action
requires Koha's `plugins:tool` permission and queues the same install/cache
refresh routine as the script above on the `long_tasks` queue. It redirects
to Koha's background-job details, including completion time or error messages.
The `long_tasks` worker must be running. Concurrent refresh jobs are rejected
using a database advisory lock; do not run the command-line refresh concurrently.
Once started, the full rebuild cannot be interrupted by cancelling its job.
Existing cache refresh behavior is unchanged: derived caches are rebuilt and
bibliographic facet mappings are reset as described above; original MARC,
items and authority records are not changed. Some lookup tables may be
temporarily incomplete during the refresh, so schedule it outside busy periods.

After deploying this action, refresh the plugin method registry (see below),
reload Plack, and restart the `long_tasks` worker so it loads the new job and
template hooks.

The `/api/v1/contrib/nm2db_keyword_search/search` endpoint also accepts
`include=results`, `include=facets`, or `include=all`. Result sets can be
narrowed with `facet_name`/`facet_value`, `refine` for an additional
search-within-results term, and `available_only=1` for records with at least
one item that is not on loan, lost, withdrawn, or not-for-loan. The static
search pages use `include` to request results and facets concurrently instead
of doing both in one server request.

The standalone search pages perform live AJAX searches and use
`/api/v1/contrib/nm2db_keyword_search/suggestions` for typeahead suggestions.
The staff plugin tool is reserved for cache maintenance; it does not contain
a keyword search form or result list. Normal staff and OPAC catalogue searches
and the standalone search pages remain available.
The typeahead matches contained text, with prefix matches ordered first. The
suggestion cache is built from a defined MARC field list, currently `245$a`.

The plugin also exposes `opac_js` and `intranet_js` hooks. When `SearchEngine`
is `DBSearch` and Koha's plugin method registry is current, those hooks add
the same title typeahead to normal
OPAC and staff catalogue search forms that submit to `opac-search.pl` or
`catalogue/search.pl`. A unique suggestion carries its `biblionumber`, so an
explicit browser typeahead replacement can jump directly to the record detail
page. Submitting the form still performs a normal keyword search.
Suggestions load while typing and when focusing a prefilled search field.
Option labels include the title so Firefox can filter and display them.
With Zebra or Elasticsearch selected, these catalogue hooks emit no JavaScript.
The standalone nm2db search page and its suggestions endpoint remain available.

## Authority search

When `SearchEngine` is `DBSearch`, authority searches also use normalized MARC
authority records instead of delegating to Zebra. The MARC21 implementation
supports the standard authority search selections: any field, main and primary
heading, matching headings, see-from headings, MARC tag/subfield searches,
thesaurus, heading-use flags, authority type, sorting, and pagination. Results
retain Koha's normal authority result metadata and summaries. Authority usage
counts are based on normalized bibliographic `$9` links.

After adding or changing hook methods in a mounted plugin checkout, refresh
Koha's plugin method registry:

```sh
perl -MKoha::Plugins -E 'Koha::Plugins->new->InstallPlugins({ include => [ q{Koha::Plugin::HKS3::NM2DBKeywordSearch} ] })'
```

## Tests

Run the catalogue typeahead JavaScript regression tests with Node.js 18 or newer
(no Koha instance or database required):

```sh
node t/catalogue_typeahead.test.cjs
```

Run the hook-selection regression test in KTD (preferences are mocked and the
plugin constructor is not called, so no catalogue data is changed):

```sh
prove -v /kohadevbox/plugins/koha-nm2db-keyword-search/t/catalogue_typeahead_hooks.t
prove -v /kohadevbox/plugins/koha-nm2db-keyword-search/t/refresh_cache_tool.t
```

The refresh-tool test mocks cache writes and checks the maintenance-only UI,
job registration, POST/CSRF guards, redirects, successful/failed refresh reports
and concurrent-job rejection.

Run the integration comparison test inside a KTD instance with the plugin mounted:

```sh
prove -v /kohadevbox/plugins/koha-nm2db-keyword-search/t/nm2db_vs_koha_search.t
prove -v /kohadevbox/plugins/koha-nm2db-keyword-search/t/dbsearch_authorities.t
prove -v /kohadevbox/plugins/koha-nm2db-keyword-search/t/word_index.t
```

The test compares this plugin's normalized-MARC keyword search with Koha's normal
catalog keyword search and fails with the differing biblionumbers if the result
sets diverge.

The word-index test checks standalone short words, stopwords, word boundaries,
multi-term matching, update invalidation and request-local hit-set reuse.
Its update fixtures only replace derived cache rows inside a rolled-back
transaction; catalogue records are not changed. The authority test includes
the one-based first-page offset used by both the staff and OPAC authority UI,
including the single-hit case and paging past the last hit.

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
