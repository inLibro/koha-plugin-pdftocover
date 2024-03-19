[% USE Koha %]

[% BLOCK process %]
[% END %]

[% SET report = job.decoded_data %]
[% BLOCK report %]
    [% IF job.status == 'finished' %]
        [% IF report %]
            <div class="dialog message">
                [% report.report.total_success | html %] covers have successfully been genereted.<br>
                [% IF report.report.total_success != report.report.total_greets %]
                    [% report.report.total_greets - report.report.total_success | html %] covers have not been genereted, see the logs for details.
                [% END %]
            </div>
        [% ELSE %]
            <div class="dialog message">
               Job data could not be read, see the logs for details
            </div>
        [% END %]
    [% ELSIF job.status == 'cancelled' %]
        <span>The job has been cancelled before it finished.</span>
    [% END %]
[% END %]

[% BLOCK detail %]
[% END %]

[% BLOCK js %]
[% END %]
