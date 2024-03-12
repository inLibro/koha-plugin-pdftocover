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

use base 'Koha::BackgroundJob';

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

sub genererVignette {
    # methode appelée si on génère les vignettes pour toutes les notices
    my ( $self, $args ) = @_;
    my $ua = LWP::UserAgent->new( timeout => "5" );
    my $table = getKohaVersion() < 21.0508000 ? "biblioimages" : "cover_images";
    my $query = "SELECT a.biblionumber, EXTRACTVALUE(a.metadata,\"record/datafield[\@tag='856']/subfield[\@code='u']\") AS url FROM biblio_metadata AS a WHERE EXTRACTVALUE(a.metadata,\"record/datafield[\@tag='856']/subfield[\@code='u']\") <> '' and a.biblionumber not in (select biblionumber from $table);";

    # Retourne 856$u, qui est le(s) URI(s) d'une ressource numérique
    my $sthSelectPdfUri = $dbh->prepare($query);
    $sthSelectPdfUri->execute();
    while ( my ( $biblionumber, $urifield ) = $sthSelectPdfUri->fetchrow_array() ) {
        my @uris = split / /, $urifield;
        $self->genererVignetteParUris($biblionumber, @uris);
        $self->store_data({ to_process => $self->retrieve_data('to_process') - 1 });
    }
    return 0;
}

sub genererVignetteParUris {
    my ( $self, $biblionumber, @uris) = @_;
    foreach my $url (@uris) {
        if ( $self->isPdfResource($url) ) {
            my @filestodelete = ();
            my $save          = C4::Context->temporary_directory();
            $save =~ s/\/*$/\//;
            $save .= $biblionumber;
            if ( is_success( getstore( $url, $save ) ) ) {
                push @filestodelete, $save;
                `pdftocairo "$save" -png "$save" -singlefile 2>&1`;    # Conversion de pdf à png, seulement pour la première page
                my $imageFile = $save . ".png";
                push @filestodelete, $imageFile;

                if ( -e $imageFile ) {
                    my $srcimage = GD::Image->new($imageFile);
                    my $replace  = 1;
                    if (getKohaVersion() < 21.0508000){
                        C4::Images::PutImage( $biblionumber, $srcimage, $replace );
                    } else {
                        my $input = CGI->new;
                        my $itemnumber = $input->param('itemnumber');
                        Koha::CoverImage->new(
                            {
                                biblionumber => $biblionumber,
                                itemnumber   => $itemnumber,
                                src_image    => $srcimage
                            }
                        )->store;
                    }
                    foreach my $file (@filestodelete) {
                        unlink $file or warn "Could not unlink $file: $!\nNo more images to import.Exiting.";
                    }  
                } else {
                    warn "No image generate for biblionumber : $biblionumber with url : $url. Invalid url\n";
                }
            }
            last;
        }
    }
    return 0;
}

sub getUrisByBiblioNumber {
    # recupere toutes les uris correspondantes a une notice
    my ( $self, $biblionumber ) = @_;

    my $query = "SELECT EXTRACTVALUE(a.metadata,\"record/datafield[\@tag='856']/subfield[\@code='u']\") AS url FROM biblio_metadata AS a WHERE EXTRACTVALUE(a.metadata,\"record/datafield[\@tag='856']/subfield[\@code='u']\") <> '' and a.biblionumber = ? ;";

    # Retourne 856$u, qui est le(s) URI(s) d'une ressource numérique
    my $stmt = $dbh->prepare($query);
    $stmt->execute($biblionumber);
    my $urifield = $stmt->fetchrow_array();

    my @uris = split / /, $urifield;
    return @uris;
}

sub isPdfResource {
    # vérifie si la ressource est un pdf
    my ( $self, $url ) = @_;
    my $ua = LWP::UserAgent->new( timeout => "5" );
    my $response = $ua->get($url);
    if ( $response->is_success ) { 
        if ($response->header('content-type') =~ /application\/pdf/) {
            return 1;
        } elsif ($response->header('content-disposition') && substr($response->header('content-disposition'), -5, 4) eq ".pdf") {
            return 1;
        }
    }
    return 0;
}

sub hasPdfResource {
    # verifie si la notice a une ressource pdf
    my ( $self, $biblionumber ) = @_;
    my @uris = $self->getUrisByBiblioNumber($biblionumber);
    foreach my $url (@uris) { 
        return $self->isPdfResource($url);
    }
    return 0;
}

sub hasAlreadyLocalImage {
    my ( $self, $biblionumber ) = @_;
    my $table = getKohaVersion() < 21.0508000 ? "biblioimages" : "cover_images";
    my $query = "select count(*) as count from $table where biblionumber = ? ;";

    my $stmt = $dbh->prepare($query);
    $stmt->execute($biblionumber);

    my $row = $stmt->fetchrow_hashref();
    return $row->{count} > 0;
}

sub getKohaVersion {
    # Current version of Koha from sources
    my $kohaversion = Koha::version;
    # remove the 3 last . to have a Perl number
    $kohaversion =~ s/(.*\..*)\.(.*)\.(.*)/$1$2$3/;
    return $kohaversion;
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

    # methode appelée si on génère les vignettes pour toutes les notices
    my $ua = LWP::UserAgent->new( timeout => "5" );
    my $table = getKohaVersion() < 21.0508000 ? "biblioimages" : "cover_images";
    my $query = "SELECT a.biblionumber, EXTRACTVALUE(a.metadata,\"record/datafield[\@tag='856']/subfield[\@code='u']\") AS url FROM biblio_metadata AS a WHERE EXTRACTVALUE(a.metadata,\"record/datafield[\@tag='856']/subfield[\@code='u']\") <> '' and a.biblionumber not in (select biblionumber from $table);";

    # Retourne 856$u, qui est le(s) URI(s) d'une ressource numérique
    my $sthSelectPdfUri = $dbh->prepare($query);
    $sthSelectPdfUri->execute();
    while ( my ( $biblionumber, $urifield ) = $sthSelectPdfUri->fetchrow_array() ) {
        try {
            my @uris = split / /, $urifield;
            $self->genererVignetteParUris($biblionumber, @uris);
            $self->store_data({ to_process => $self->retrieve_data('to_process') - 1 });

            push @messages,
                {
                type => 'success',
                code => 'image_generated',
                };

            $report->{total_success}++;
        }
        catch {
            push @messages,
                {
                type => 'error',
                code => 'image_not_generated',
                };
        };
        $self->step;
    }

    my $data = $self->decoded_data;
    $data->{messages} = \@messages;
    $data->{report}   = $report;

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
            job_args => {},
        }
    );
}

1;
