[% USE Koha %]

[% BLOCK process %]
[% END %]

[% SET report = job.decoded_data %]
[% BLOCK report %]
    [% IF job.status == 'finished' %]
        [% IF report %]
            <div class="dialog message">
                [% report.report.total_success | html %] couvertures ont été générées avec succès.<br>
                [% IF report.report.total_success != report.report.total_greets %]
                    [% report.report.total_greets - report.report.total_success | html %] couvertures n'ont pas été générées, veuillez vérifier les registres pour plus d'information.
                [% END %]
            </div>
        [% ELSE %]
            <div class="dialog message">
                Les données de la tâche sont illisibles, veuillez vérifier les registres pour plus d'information. </div>
            </div>
        [% END %]
    [% ELSIF job.status == 'cancelled' %]
        <span>La tâche a été annulée avant de finir.</span>
    [% END %]
[% END %]

[% BLOCK detail %]
[% END %]

[% BLOCK js %]
[% END %]
