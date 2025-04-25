package Koha::Plugin::PDFtoCover;

# Mehdi Hamidi, 2016 - InLibro
# Modified by : Bouzid Fergani, 2016 - InLibro
#
# This plugin allows you to generate a Carrousel of books from available lists
# and insert the template into the table system preferences;OpacMainUserBlock
#
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
use Modern::Perl;
use Try::Tiny;
use strict;
use warnings;
use CGI;
use LWP::UserAgent;
use LWP::Simple;
use base qw(Koha::Plugins::Base);
use C4::Auth;
use C4::Context;
use File::Spec;
use JSON qw( encode_json );
use URI::Escape;
use Koha::Plugin::PDFtoCover::PDFtoCoverGreeter;
use Koha::BackgroundJobs;

BEGIN {
    my $kohaversion = Koha::version;
    $kohaversion =~ s/(.*\..*)\.(.*)\.(.*)/$1$2$3/;
    my $module = "Koha::CoverImages";
    my $file = $module;
    $file =~ s[::][/]g;
    $file .= '.pm';
    require $file;
    $module->import;
}

our $dbh      = C4::Context->dbh();
our $VERSION  = 2.3;
our $metadata = {
    name            => 'PDFtoCover',
    author          => 'Mehdi Hamidi, Bouzid Fergani, Arthur Bousquet, The Minh Luong, Matthias Le Gac',
    description     => 'Creates cover images for documents missing one',
    date_authored   => '2016-06-08',
    date_updated    => '2024-03-19',
    minimum_version => '23.05.08',
    version         => $VERSION,
    namespace       => 'pdftocover',
};

sub new {
    my ( $class, $args ) = @_;
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;
    my $self = $class->SUPER::new($args);
    $self->{cgi} = CGI->new();
    return $self;
}

sub tool {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};

    my $poppler = "/usr/bin/pdftocairo";
    unless (-e $poppler){
        $self->missingModule();
    }

    if ( $cgi->param('greet') ) {
        my $pdf = $self->displayAffected();
        $self->store_data({ to_process => $pdf });

        $self->{greeter} = Koha::Plugin::PDFtoCover::PDFtoCoverGreeter->new;
        $self->{greeter}->enqueue( { size => $pdf, one_image => 0 } );
        my $id_job = $self->{greeter}->id;

        $self->store_data({ errors => '' });
        $self->step_1(1, 0, 0, $id_job, '');

        exit 0;
    } elsif ( $cgi->param('stop') ) {
        my $id_job = $cgi->param('id_job');
        Koha::BackgroundJobs->search({ id => $id_job })->next->cancel;
        $self->step_1(0, 0, 1, '', $self->retrieve_data('errors'));
    } elsif ( $cgi->param('done') ) {
        $self->step_1(0, 1, 0, '', $self->retrieve_data('errors'));
    } else {
        $self->step_1(0, 0, 0, '', '');
    }
}

sub step_1 {
    my ( $self, $wait, $done, $cancel, $id_job, $errors ) = @_;
    my $cgi = $self->{'cgi'};
    my $pdf = $self->displayAffected();

    my $template = $self->retrieve_template('step_1');
    $template->param( pdf  => $pdf );
    $template->param( wait => $wait );
    $template->param( done => $done );
    $template->param( cancel => $cancel );
    $template->param( id_job => $id_job );
    $template->param( errors => [split(',', $errors)] );
    print $cgi->header( -type => 'text/html', -charset => 'utf-8' );
    print $template->output();
}

sub missingModule {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my $template = $self->retrieve_template('missingModule');
    print $cgi->header( -type => 'text/html', -charset => 'utf-8' );
    print $template->output();
}

sub getKohaVersion {
    # Current version of Koha from sources
    my $kohaversion = Koha::version;
    # remove the 3 last . to have a Perl number
    $kohaversion =~ s/(.*\..*)\.(.*)\.(.*)/$1$2$3/;
    return $kohaversion;
}

sub displayAffected {
    my ( $self, $args ) = @_;
    my $query = "SELECT count(*) as count FROM biblio_metadata AS a WHERE EXTRACTVALUE(a.metadata,\"record/datafield[\@tag='856']/subfield[\@code='u']\") <> '' and a.biblionumber not in (select biblionumber from cover_images where biblionumber is not NULL);";
    my $stmt = $dbh->prepare($query);
    $stmt->execute();

    if ( my $row = $stmt->fetchrow_hashref() ) {
        return $row->{count};
    }
    return 0;
}

sub genererVignette {
    # methode appelée si on génère les vignettes pour toutes les notices
    my ( $self, $args ) = @_;
    my $ua = LWP::UserAgent->new( timeout => "5" );
    my $table = "cover_images";
    my $query = "SELECT a.biblionumber, EXTRACTVALUE(a.metadata,\"record/datafield[\@tag='856']/subfield[\@code='u']\") AS url FROM biblio_metadata AS a WHERE EXTRACTVALUE(a.metadata,\"record/datafield[\@tag='856']/subfield[\@code='u']\") <> '' and a.biblionumber not in (select biblionumber from $table where biblionumber is not NULL);";

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

sub genererUneVignette {
    # methode appelée si on génère la vignette pour une notice spécifique
    my ( $self, $params) = @_;
    my $biblionumber = $self->{cgi}->param('biblionumber');
    if ($self->{cgi}->param('regenerer')) { # On supprime l'image si elle a été générée par le passé
        my $query = "DELETE FROM cover_images WHERE biblionumber = ?";
        my $stmt = $dbh->prepare($query);
        $stmt->execute($biblionumber)
    }
    Koha::Plugin::PDFtoCover::PDFtoCoverGreeter->new->enqueue( { size => 1, biblionumber => $biblionumber, one_image => 1 } );
    sleep(10);
    print $self->{cgi}->redirect(-url => '/cgi-bin/koha/catalogue/detail.pl?biblionumber=' . $biblionumber);
    exit 0;
}

sub genererVignetteParUris {
    my ( $self, $biblionumber, @uris) = @_;
    my $not_pdf = 1;
    foreach my $url (@uris) {
        if ( $self->isPdfResource($url) ) {
            my @filestodelete = ();
            my $save          = C4::Context->temporary_directory();
            $save =~ s/\/*$/\//;
            $save .= $biblionumber;
            if ( is_success( getstore( $url, $save ) ) ) {
                try {
                    $not_pdf = 0;
                    push @filestodelete, $save;
                    `pdftocairo "$save" -png "$save" -singlefile 2>&1`;    # Conversion de pdf à png, seulement pour la première page
                    my $imageFile = $save . ".png";
                    push @filestodelete, $imageFile;

                    my $srcimage = GD::Image->new($imageFile);
                    my $replace  = 1;
            
                    my $input = CGI->new;
                    my $itemnumber = $input->param('itemnumber');
                    Koha::CoverImage->new(
                        {
                            biblionumber => $biblionumber,
                            itemnumber   => $itemnumber,
                            src_image    => $srcimage
                        }
                    )->store;

                    foreach my $file (@filestodelete) {
                        unlink $file or warn "Could not unlink $file: $!\nNo more images to import.Exiting.";
                    }
                } catch {
                    my $error = $_;
                    warn "Invalid $url: $error\n";
                    die $error;
                };
            }
            last;
        }
    }
    return $not_pdf;
}

sub getUrisByBiblioNumber {
    # recupere toutes les uris correspondantes a une notice
    my ( $self, $biblionumber ) = @_;

    my $query = "SELECT EXTRACTVALUE(a.metadata,\"record/datafield[\@tag='856']/subfield[\@code='u']\") AS url FROM biblio_metadata AS a WHERE EXTRACTVALUE(a.metadata,\"record/datafield[\@tag='856']/subfield[\@code='u']\") <> '' and a.biblionumber = ? ;";

    # Retourne 856$u, qui est le(s) URI(s) d'une ressource numérique
    my $stmt = $dbh->prepare($query);
    $stmt->execute($biblionumber);
    my $urifield = $stmt->fetchrow_array();

    my @uris;
    @uris = split / /, $urifield if ($urifield);
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
    my $table = "cover_images";
    my $query = "select count(*) as count from $table where biblionumber = ? ;";

    my $stmt = $dbh->prepare($query);
    $stmt->execute($biblionumber);

    my $row = $stmt->fetchrow_hashref();
    return $row->{count} > 0;
}

sub intranet_catalog_biblio_enhancements_toolbar_button { # hook koha
    # Ajoute un bouton a la barre d'outils de la page detail.pl pour generer la vignette
    my ( $self, $params ) = @_;
    my $cgi = $self->{cgi};
    my $biblionumber = $cgi->param('biblionumber');

    # On affiche un bouton que s'il y a une ressource pdf 
    if ($self->hasPdfResource($biblionumber)) { 
        my $lang = C4::Languages::getlanguage($self->{'cgi'});
        my $hasLocalImage = $self->hasAlreadyLocalImage($biblionumber);
        my $stmt = $dbh->prepare("select value from systempreferences where variable='LocalCoverImages'");
        $stmt->execute();

        my $button = "<div class='btn-group'>";
        my $textbutton = $lang eq "fr-CA" || $lang eq "fr" ? "G&eacute;n&eacute;rer l'image de couverture" : "Generate cover image";
        if ($hasLocalImage) {
            $textbutton = "Reg" . substr($textbutton, 1);
        }


        if ($stmt->fetchrow_array()) {
            my $link = "/cgi-bin/koha/plugins/run.pl?class=" . uri_escape("Koha::Plugin::" . $metadata->{name}) . 
                "&method=genererUneVignette&biblionumber=" . $biblionumber . ($hasLocalImage ? "&regenerer=1" : "");

            my $class = "<i class='fa fa-" . ($hasLocalImage ? "refresh" : "picture-o") . "'></i>&nbsp;";

            $button .= "<a id='cover-$biblionumber' class='btn btn-default' href='$link'>$class $textbutton</a>";
        } else {
            my $title = "You must activate the LocalCoverImages system preference to generate the cover image"; 
            if ($lang eq "fr-CA" || $lang eq "fr") {
                $title = "Vous devez activer la pr&eacute;f&eacute;rence syst&egrave;me LocalCoverImages pour g&eacute;n&eacute;rer l'image de couverture";
            }

            $button .= "<button type='button' class='btn btn-default' title=\"$title\" disabled><i class='fa fa-exclamation-triangle'></i>&nbsp;$textbutton</button>";
        }
        return $button . "</div>";
    }
    return "";
}

sub progress {
    my ($self) = @_;
    print $self->{'cgi'}->header( -type => 'application/json', -charset => 'utf-8' );
    print encode_json({ to_process => $self->retrieve_data('to_process') });
    exit 0;
}

# retrieve the template that includes the prefix passed
# 'step_1'
# 'missingModule'
sub retrieve_template {
    my ( $self, $template_prefix ) = @_;
    my $cgi = $self->{'cgi'};

    return undef unless $template_prefix eq 'step_1' || $template_prefix eq 'missingModule';

    my $preferedLanguage = $cgi->cookie('KohaOpacLanguage');
    my $template = undef;
    eval {
        $template  = $self->get_template({ file => $template_prefix . '_' . $preferedLanguage . ".tt" })
    };

    if ( !$template ) {
        $preferedLanguage = substr $preferedLanguage, 0, 2;
        eval {
            $template = $self->get_template( { file => $template_prefix . '_' . $preferedLanguage .  ".tt" })
        };
    }

    $template = $self->get_template( { file => $template_prefix . '.tt' } ) unless $template;
    return $template;
}

sub background_tasks {
    return {
        greeter => 'Koha::Plugin::PDFtoCover::PDFtoCoverGreeter'
    };
}

sub template_include_paths {
    my ($self, $args) = @_;

    if ( $args->{lang} eq 'fr' ) {
        return [
            $self->mbf_path('inc/fr'),
        ]
    } elsif ( $args->{lang} eq 'fr-CA' ) {
        return [
            $self->mbf_path('inc/fr-CA'),
        ]
    } else {
        return [
            $self->mbf_path('inc/en'),
        ]
    }
}

#Supprimer le plugin avec toutes ses données
sub uninstall() {
    my ( $self, $args ) = @_;
    return 1;
}

1;
