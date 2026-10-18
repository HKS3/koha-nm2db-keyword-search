[% BLOCK report %]
    [% IF job.status == 'finished' %]
        <div class="dialog message">NM2DB keyword search caches refreshed in [% job.report.elapsed_seconds | html %] seconds.</div>
    [% ELSIF job.status == 'failed' %]
        <div class="dialog alert">The cache refresh failed. Check the detailed messages and Koha logs before retrying.</div>
    [% ELSIF job.status == 'cancelled' %]
        <div class="dialog alert">The job was cancelled. A refresh already in progress cannot be interrupted and may still update the caches.</div>
    [% ELSE %]
        <div class="dialog message">The cache refresh is running.</div>
    [% END %]
    <p><a href="/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::HKS3::NM2DBKeywordSearch&amp;method=tool">Return to NM2DB Keyword Search</a></p>
[% END %]

[% BLOCK detail %]
    [% FOR error IN job.messages %]
        <div class="dialog alert">[% error.message | html %]</div>
    [% END %]
[% END %]

[% BLOCK js %]
[% END %]
