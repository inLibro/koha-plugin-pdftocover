package Koha::Plugin::PDFtoCover::PDFtoCoverGreeter;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;
use Try::Tiny;
use C4::Context;
use Koha::Plugin::PDFtoCover;
use Koha::BackgroundJobs;

use base 'Koha::BackgroundJob';

our $dbh = C4::Context->dbh();

=head1 NAME

PDFtoCover::PDFtoCoverGreeter - Background task for greeting in the logs

This is a subclass of Koha::BackgroundJob.

=head1 API

=head2 Class methods

=head3 job_type

Define the job type of this job: greeter

=cut

sub job_type {
    return 'plugin_pdftocover_greeter';
}

=head3 process

Process the modification.

=cut

sub process {
    my ( $self, $args ) = @_;

    $self->start;

    my @messages;
    my $report = {
        total_greets  => $self->size,
        total_success => 0,
    };

    my $pdfToCover = Koha::Plugin::PDFtoCover->new();
    if ( $args->{one_image}) {
        my $biblionumber = $args->{biblionumber};
        my @uris = $pdfToCover->getUrisByBiblioNumber($biblionumber);
        $pdfToCover->genererVignetteParUris($biblionumber, @uris);
        $self->step;
        $report->{total_success}++;
    } else {
        my $ua = LWP::UserAgent->new( timeout => "5" );
        my $query = "SELECT a.biblionumber, EXTRACTVALUE(a.metadata,\"record/datafield[\@tag='856']/subfield[\@code='u']\") AS url FROM biblio_metadata AS a WHERE EXTRACTVALUE(a.metadata,\"record/datafield[\@tag='856']/subfield[\@code='u']\") <> '' and a.biblionumber not in (select biblionumber from cover_images where biblionumber is not NULL);";

        my $sthSelectPdfUri = $dbh->prepare($query);
        $sthSelectPdfUri->execute();
        
        while ( my ( $biblionumber, $urifield ) = $sthSelectPdfUri->fetchrow_array() ) {
            Koha::BackgroundJobs->search({ id => $self->id })->next->status eq 'cancelled' and last;
            try {
                my @uris = split / /, $urifield;
                my $no_pdf = $pdfToCover->genererVignetteParUris($biblionumber, @uris);
                $pdfToCover->store_data({ to_process => $pdfToCover->retrieve_data('to_process') - 1 });

                if ( $no_pdf ) {
                    my $error = 'No PDF url found or bad PDF url for biblionumber ' . $biblionumber;
                    warn "$error\n";
                    push @messages, {
                        type => 'error',
                        code => 'image_generation_failed_for_biblio_' . $biblionumber,
                        error => $error,
                    };
                } else {
                    $report->{total_success}++;
                }
                
                $self->step;
            } catch {
                push @messages, {
                    type => 'error',
                    code => 'image_generation_failed_for_biblio_' . $biblionumber,
                    error => $_,
                };
            };
        }

        my $messages_string = join("\n", map { $_->{type} . ": " . $_->{error} . "," } @messages);
        $pdfToCover->store_data({ errors => $messages_string });
        $pdfToCover->store_data({ to_process => 0 });
    }
    
    my $data = $self->decoded_data;
    $data->{report} = $report;

    $self->finish($data);
}

=head3 enqueue

Enqueue the new job

=cut

sub enqueue {
    my ( $self, $args ) = @_;

    $self->SUPER::enqueue(
        {
            job_size => $args->{size} // 5,
            job_args => $args,
            job_queue => 'long_tasks',
        }
    );
}

=head3 cancel

Cancel the job

=cut

sub cancel {
    my ( $self ) = @_;

    $self->SUPER::cancel;
}

1;
