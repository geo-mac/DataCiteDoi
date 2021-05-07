package EPrints::Plugin::Screen::EPrint::Staff::CoinDOI;

#use EPrints::Plugin::Screen::EPrint;

use EPrints::DataCite::Utils;

@ISA = ( 'EPrints::Plugin::Screen::EPrint' );

use strict;

sub new
{
        my( $class, %params ) = @_;

        my $self = $class->SUPER::new(%params);

        #       $self->{priv} = # no specific priv - one per action

        $self->{actions} = [qw/ coindoi claimdoi /];

        $self->{appears} = [ {
                place => "eprint_editor_actions",
                #action => "coindoi",
                position => 1977,
        }, ];

        return $self;
}

sub obtain_lock
{
        my( $self ) = @_;

        return $self->could_obtain_eprint_lock;
}

sub properties_from
{
    my( $self ) = @_;
    
    my $repo = $self->repository;
    $self->SUPER::properties_from;

    my $eprint = $self->{processor}->{eprint};

    # get the DOI this eprint wants to generate
    my $eprint_doi = EPrints::DataCite::Utils::generate_doi( $repo, $eprint );
    $self->{processor}->{eprint_doi} = $eprint_doi;

    # Does the DOI that would be generated for this record already exist?
    my $mds_doi = EPrints::DataCite::Utils::datacite_mds_doi( $repo, $eprint_doi );
    $self->{processor}->{mds_doi} = $mds_doi if defined $mds_doi;

    # DataCite title query to look for any DOIs that might already represent this record
    $self->{processor}->{datacite_response} = EPrints::DataCite::Utils::datacite_api_query( $repo, "titles.title", $eprint->value( "title" ) );

    # used when claiming an exisiting DOI from DataCite
    if( defined ( my $doi = $repo->param( "doi" ) ) )
    {
        $self->{processor}->{doi} = $doi;
    }
}

sub render
{
    my( $self ) = @_;

    my $repo = $self->{session};
    my $eprint = $self->{processor}->{eprint};

    my $frag = $repo->make_doc_fragment;

    # if no doi present, we want the opportunity to coin one, show any potential problems, and show DOIs that might already exist
    my $eprintdoifield = $repo->get_conf( "datacitedoi", "eprintdoifield" );
    if( !$eprint->is_set( $eprintdoifield ) )
    {
        $frag->appendChild( $self->render_coin_doi );
    }
    else # we already have a DOI
    {
        $frag->appendChild( $self->html_phrase( "current_doi", doi => $eprint->render_value( $eprintdoifield ) ) );
    }

    # DataCite XML
    my $box = $repo->make_element( "div", style=>"text-align: left" );
    $box->appendChild( EPrints::Box::render(
        id => "datacite_xml",
        title => $self->html_phrase( "data:title" ),
        content => $self->render_xml,
        collapsed => 1,
        session => $repo,
    ) );
    $frag->appendChild( $box );

    return $frag;
}

# all the options for adding a DOI to this record including listing problems with the record, indexer events trying to coin a DOI, and DOIs that already exist on DataCite
sub render_coin_doi
{
    my( $self ) = @_;

    my $repo = $self->{repository};
    my $eprint = $self->{processor}->{eprint};

    my $div = $repo->make_element( "div", class => "coin_doi" );

    # title and description
    $div->appendChild( $self->html_phrase( "coin:title" ) );
    $div->appendChild( $self->html_phrase( "coin:intro" ) );

    ### Coin a New DOI ###
    # first show any warnings
    my $problems = $self->validate( $eprint );
    if( scalar @{$problems} > 0 )
    {
        my $coin_problems = $repo->make_element( "div", class => "coin_problems" );
        $coin_problems->appendChild( $self->html_phrase( "coin_problems:title" ) );       
        $coin_problems->appendChild( $self->html_phrase( "coin_problems:intro" ) );

        my $coin_problems_list = $coin_problems->appendChild( $repo->make_element( "ul" ) );
        foreach my $problem_xhtml ( @{$problems} )
        {
            my $li = $coin_problems_list->appendChild( $repo->make_element( "li", class => "coin_warning" ) );
            $li->appendChild( $problem_xhtml );            
        }
        $div->appendChild( $coin_problems );
    }
    elsif( defined $self->{processor}->{mds_doi} ) # the doi we would make for this record already exists... something odd going on
    {
        my $existing_doi = $repo->make_element( "div", class => "existing_doi" );
        $div->appendChild( $existing_doi );
        if( $self->{processor}->{mds_doi}."/" eq $eprint->get_url ) # the doi already exists and points to us... let's claim it 
        # TODO: improve the above if statement with some sort of nice regex??  BUt hopefully this sort of occurence is quite rare anyway!
        {
            $existing_doi->appendChild( $self->html_phrase( "existing_doi:our_doi" ) );

            # button to set the eprints doi field
            my $claim_div = $existing_doi->appendChild( $repo->make_element( "div", class => "datacite_claim" ) );
            my $form = $self->render_form;
            $form->appendChild( $repo->render_hidden_field( "doi", $self->{processor}->{eprint_doi} ) );
            $form->appendChild( $self->{session}->render_action_buttons(
                claimdoi => $self->{session}->phrase( "datacite_dois:claim_doi" ),
            ) );
            $claim_div->appendChild( $form );
        }
        else # the doi we would coin already exists and points elsewhere... very odd so let's explain the situation
        {
            my $external_link = $repo->make_element( "a", href => $self->{processor}->{mds_doi}, target => "_blank" );
            $external_link->appendChild( $repo->make_text( $self->{processor}->{mds_doi} ) );
            $existing_doi->appendChild( $self->html_phrase( "existing_doi:external", url => $external_link ) );
        }
    }
    else # we're all good to coin a doi
    {
        my $new_doi = $repo->make_element( "div", class => "new_doi" );
        $new_doi->appendChild( $self->html_phrase( "new_doi:intro" ) );
        my $form = $self->render_form( "get" );
        $form->appendChild( $repo->render_action_buttons(
            _order => [ "coindoi" ],
            coindoi => $repo->phrase( "Plugin/Screen/EPrint/Staff/CoinDOI:action:coindoi:title" ) )
        );
        $new_doi->appendChild( $form );
        $div->appendChild( $new_doi );
    }

    ### Show existing DOIs on DataCite ###
    $div->appendChild( $self->render_datacite_dois );

    return $div;
}

# show the results of looking up this eprint's title on datacite
sub render_datacite_dois
{
    my( $self ) = @_;

    my $repo = $self->{repository};
    my $eprint = $self->{processor}->{eprint};

    my $div = $repo->make_element( "div", class => "datacite_dois" );

    # title and description
    $div->appendChild( $self->html_phrase( "datacite_dois:title" ) );

    my $datacite_response = $self->{processor}->{datacite_response};
    if( exists $datacite_response->{results} && scalar @{$datacite_response->{results}} > 0 ) # success, show results
    {
        foreach my $result ( @{$datacite_response->{results}} )
        {
            $div->appendChild( $self->render_datacite_result( $result ) );
        }
    }
    elsif( exists $datacite_response->{error} ) # an actual error from the api
    {
        $div->appendChild( $self->html_phrase( "datacite_dois:error_message", code => $repo->make_text( $datacite_response->{code} ) ) );
    }
    else # no results... :(
    {
        $div->appendChild( $self->html_phrase( "datacite_dois:no_results", title => $eprint->render_value( "title" ) ) );
    }

    return $div;
}

# show a datacite record, with a button allowing the user to select this doi for their eprint
sub render_datacite_result
{
    my( $self, $result ) = @_;

    my $repo = $self->{repository};
    my $eprint = $self->{processor}->{eprint};

    my $div = $repo->make_element( "div", class => "datacite_result" );

    # datacite info
    my $datacite_div = $div->appendChild( $repo->make_element( "div", class => "datacite_info" ) );
    my $link = $repo->make_element( "a", href => $result->{url}, target => "_blank" );
    $link->appendChild( $repo->make_text( $result->{title} ) );

    $datacite_div->appendChild( $self->html_phrase( "datacite_dois:datacite_result",
        title => $link,
        date => $repo->make_text( $result->{date} ),
        publisher => $repo->make_text( $result->{publisher} ),
        doi => $repo->make_text( $result->{doi} ),
    ) );

    # claim button
    my $claim_div = $div->appendChild( $repo->make_element( "div", class => "datacite_claim" ) );
    my $form = $self->render_form;
    $form->appendChild( $repo->render_hidden_field( "doi",  $result->{doi} ) );
    $form->appendChild( $self->{session}->render_action_buttons(
        claimdoi => $self->{session}->phrase( "datacite_dois:claim_doi" ),
    ) );
    $claim_div->appendChild( $form );

    return $div;
}

# show the xml that the datacite export plugin produces and would send off to datacite when coining
sub render_xml
{
    my( $self ) = @_;

    my $repo = $self->{repository};
    my $eprint = $self->{processor}->{eprint};

    my $pre = $repo->make_element( "pre" );

    my $xml = $eprint->export( "DataCiteXML" );
    $pre->appendChild( $repo->make_text( $xml ) );

    return $pre;
}

sub allow_coindoi
{
    my( $self ) = @_;
    return 0 unless $self->could_obtain_eprint_lock;
 
	my $repository = $self->{repository};
	#TODO a version that works for documents too
	my $dataobj = $self->{processor}->{eprint}; 
    if (defined $repository->get_conf( "datacitedoi", "typesallowed")) {
      # Is this type of eprint allowed/denied coining?
      return 0 unless $repository->get_conf( "datacitedoi", "typesallowed",  $dataobj->get_type);
    }
    return 0 unless $repository->get_conf( "datacitedoi", "eprintstatus",  $dataobj->value( "eprint_status" ));
    # Don't show coinDOI button if a DOI is already set AND coining of custom doi is disallowed
    return 0 if($dataobj->is_set($repository->get_conf( "datacitedoi", "eprintdoifield")) && 
        !$repository->get_conf("datacitedoi","allow_custom_doi"));
	#TODO don't allow the coinDOI button if a DOI is already registered (may require a db flag for successful reg)
    # Or maybe check with datacite api to see if a doi is registered
    return $self->allow( $repository->get_conf( "datacitedoi", "minters") );
}

sub action_coindoi
{
    my( $self ) = @_;
    my $repository = $self->{repository};

    return undef if (!defined $repository);

    $self->{processor}->{redirect} = $self->redirect_to_me_url()."&_current=2";

    my $eprint = $self->{processor}->{eprint};

    if (defined $eprint) {
        

        my $problems = $self->validate($eprint);
            
        if( scalar @{$problems} > 0 )
        {
            my $dom_problems = $self->{session}->make_element("ul");
            foreach my $problem_xhtml ( @{$problems} )
            {
                $dom_problems->appendChild( my $li = $self->{session}->make_element("li"));
                $li->appendChild( $problem_xhtml );
            }
            $self->workflow->link_problem_xhtml( $dom_problems, "EPrint::Edit" );
            $self->{processor}->add_message( "warning", $dom_problems );


        }else{

            my $eprint_id = $eprint->id;
            $repository->dataset( "event_queue" )->create_dataobj({
                pluginid => "Event::DataCiteEvent",
                action => "datacite_doi",
                params => [$eprint->internal_uri],
            }); 

            $self->add_result_message( 1 );
        }
    }
}    

sub allow_claimdoi { return 1; }

# set the doi using a previously existing one we've retrieved from DataCite
sub action_claimdoi
{
    my( $self ) = @_;
    my $repository = $self->{repository};

    return undef if (!defined $repository);

    $self->{processor}->{redirect} = $self->redirect_to_me_url()."&_current=2";

    my $eprint = $self->{processor}->{eprint};
    my $doi = $self->{processor}->{doi};
    
    if( defined $eprint && defined $doi )
    {
        my $eprintdoifield = $repository->get_conf( "datacitedoi", "eprintdoifield" );
        $eprint->set_value( $eprintdoifield, $doi );
        $eprint->commit();
    }
}    


sub add_result_message
{
        my( $self, $ok ) = @_;

        if( $ok )
        {
                $self->{processor}->add_message( "message",
                        $self->html_phrase( "coiningdoi" ) );
        }
        else
        {
                # Error?
                $self->{processor}->add_message( "error" );
        }

        $self->{processor}->{screenid} = "EPrint::View";
}

# Validate this datacite submission - this will call validate_datacite in lib/cfg.d/z_datacite_mapping.pl
sub validate
{
	my( $self, $eprint ) = @_;

	my @problems;

	my $validate_fn = "validate_datacite";
	if( $self->{session}->can_call( $validate_fn ) )
	{
		push @problems, $self->{session}->call( 
			$validate_fn,
			$eprint, 
			$self->{session}  );
	}

	return \@problems;
}


1;
