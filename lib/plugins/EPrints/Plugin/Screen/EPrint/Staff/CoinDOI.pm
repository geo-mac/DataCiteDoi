package EPrints::Plugin::Screen::EPrint::Staff::CoinDOI;

#use EPrints::Plugin::Screen::EPrint;

use EPrints::DataCite::Utils;

@ISA = ( 'EPrints::Plugin::Screen::EPrint' );

use strict;

sub new
{
    my( $class, %params ) = @_;

    my $self = $class->SUPER::new(%params);

    # $self->{priv} = # no specific priv - one per action

    $self->{actions} = [qw/ coindoi claimdoi reservedoi /];

    $self->{appears} = [ {
        place => "eprint_editor_actions",
        position => 1977,
    }, ];

    return $self;
}

sub obtain_lock
{
    my( $self ) = @_;

    return $self->could_obtain_eprint_lock;
}

sub can_be_viewed
{
    my( $self ) = @_;

    return 0 unless $self->could_obtain_eprint_lock;

    my $repo = $self->repository;
    my $eprint = $self->{processor}->{eprint};

    if( defined $repo->get_conf( "datacitedoi", "typesallowed" ) )
    {
        # Is this type of eprint allowed/denied coining?
        return 0 unless $repo->get_conf( "datacitedoi", "typesallowed",  $eprint->get_type );
    }

    return 0 unless $repo->get_conf( "datacitedoi", "eprintstatus",  $eprint->value( "eprint_status" ) );

    return $self->allow( $repo->get_conf( "datacitedoi", "minters" ) );
}

sub properties_from
{
    my( $self ) = @_;
    
    my $repo = $self->repository;
    $self->SUPER::properties_from;

    my $eprint = $self->{processor}->{eprint};
    my $eprint_id = $eprint->id;

    # get the fields where we would store a doi
    my $eprint_doi_field = $repo->get_conf( "datacitedoi", "eprintdoifield" );
    $self->{processor}->{eprint_field} = $eprint_doi_field;
    $self->{processor}->{document_field} = $repo->get_conf( "datacitedoi", "documentdoifield" );

    # get the DOI this eprint wants to generate
    my $eprint_doi = EPrints::DataCite::Utils::generate_doi( $repo, $eprint );
    $self->{processor}->{eprint_doi} = $eprint_doi;

    # Does the DOI that would be generated for this record already exist, either in draft form of some other form
    my $datacite_doi = EPrints::DataCite::Utils::datacite_doi_query( $repo, $eprint_doi );

    # store status
    $self->{processor}->{eprint}->{$eprint_id}->{datacite_data} = $datacite_doi->{data} if defined $datacite_doi;

    # only check for existing document dois if this repository can coin doc dois and present landing pages for them
    if( $repo->get_conf( "datacitedoi", "document_dois" ) )
    {
        foreach my $doc ( $eprint->get_all_documents )
        {
            my $doc_id = $doc->id;
            my $doc_doi = EPrints::DataCite::Utils::generate_doi( $repo, $doc );
            my $datacite_doc_doi = EPrints::DataCite::Utils::datacite_doi_query( $repo, $doc_doi );
            $self->{processor}->{document}->{$doc_id}->{datacite_data} = $datacite_doc_doi->{data} if defined $datacite_doc_doi;        
        }
    }

    # DataCite title query to look for any DOIs that might already represent this record
    if( !$eprint->is_set( $eprint_doi_field ) )
    {
        $self->{processor}->{datacite_response} = EPrints::DataCite::Utils::datacite_api_query( $repo, "titles.title", $eprint->value( "title" ) );
    }
}

sub render
{
    my( $self ) = @_;

    my $repo = $self->{session};
    my $eprint = $self->{processor}->{eprint};

    my $frag = $repo->make_doc_fragment;

    # present datacite info and options for the eprint and its documents
    $frag->appendChild( $self->render_dataobj( $eprint ) );

    # present a collapsible box for each document (if we can coin dois for documents)
    if( $repo->get_conf( "datacitedoi", "document_dois" ) )
    {   
        foreach my $doc ( $eprint->get_all_documents )
        {
            $frag->appendChild( $self->render_dataobj( $doc ) );
        }
    }
    

    return $frag;
}

sub render_dataobj
{
    my( $self, $dataobj ) = @_;

    my $repo = $self->{repository};

    ### initialise with data we may need
    my $class = $dataobj->get_dataset_id;
    my $dataobj_id = $dataobj->id;

    my $doi_field = $self->{processor}->{$class.'_field'};
    my $dataobj_doi = EPrints::DataCite::Utils::generate_doi( $repo, $dataobj );

    my $datacite_data;
    $datacite_data = $self->{processor}->{$class}->{$dataobj_id}->{datacite_data} if exists $self->{processor}->{$class}->{$dataobj_id};

    ### start rendering
    my $div = $repo->make_element( "div", class => "datacite_$class" );

    ## display basic info about the dataobj
    my $info_div = $div->appendChild( $repo->make_element( "div", class => "datacite_info" ) );

    # dataobj citation
    my $citation_div = $div->appendChild( $repo->make_element( "div", class => "datacite_citation" ) );
    $citation_div->appendChild( $dataobj->render_citation_link );

    # dataobj doi
    my $doi_div = $div->appendChild( $repo->make_element( "div", class => "datacite_doi" ) );

    # if set display the current doi
    if( $dataobj->is_set( $doi_field ) ) 
    {
        $doi_div->appendChild( $self->html_phrase( "dataobj_doi", doi => $dataobj->render_value( $doi_field ) ) );
    }
    else # display the doi we could coin
    {
        # does this doi exist in datacite as a findable item, if so display as link
        if( defined $datacite_data && $datacite_data->{attributes}->{state} eq "findable" )
        {
            my $doi_link = $repo->make_element( "a", href => $dataobj_doi );
            $doi_link->appendChild( $repo->make_text( $dataobj_doi ) );
            $doi_div->appendChild( $self->html_phrase( "dataobj_doi", doi => $doi_link ) );  
        }
        else # display uncoined doi as plain text
        {
            $doi_div->appendChild( $self->html_phrase( "dataobj_doi", doi => $repo->make_text( $dataobj_doi ) ) );  
        }
    }

    ## status/options
    # is it an external doi
    if( $dataobj->is_set( $doi_field ) && lc $dataobj->value( $doi_field ) ne lc $dataobj_doi ) #
    {
        # display message saying it's an external doi
        $div->appendChild( $self->render_external( $dataobj ) );
    }
    # no local record but this doi has been registered
    elsif( !$dataobj->is_set( $doi_field ) && defined $datacite_data && ( $datacite_data->{attributes}->{state} eq "findable" || $datacite_data->{attributes}->{state} eq "registered" ) )
    {
        # show the URL the DOI points to and present option to claim it - this is an odd state, it implies we once coined it, but have since unset the doi field
        $div->appendChild( $self->render_existing( $dataobj, $datacite_data ) );
    }
    # the doi may or may not be set, and we want show info/options for reserving and coining it
    else
    {
        # show reserve status (reservable, reserved, findable)
        unless( defined $datacite_data && ( $datacite_data->{attributes}->{state} eq "findable" || $datacite_data->{attributes}->{state} eq "registered" ) )
        {
           $div->appendChild( $self->render_reserve( $dataobj, $dataobj_doi, $datacite_data ) );
        }

        # show coin status (can't coin, newly coin, or update coin)
        $div->appendChild( $self->render_coin( $dataobj, $dataobj_doi, $datacite_data ) );
    }

    # if we're an eprint we might be able to find potential dois in datacite
    if( $class eq "eprint" && !$dataobj->is_set( $doi_field ) )
    {
        $div->appendChild( $self->render_datacite_dois( $dataobj ) );
    }

    # DataCite XML: Do people want this???
    #my $box = $repo->make_element( "div", style=>"text-align: left" );
    #$box->appendChild( EPrints::Box::render(
    #    id => "datacite_xml",
    #    title => $self->html_phrase( "data:title" ),
    #    content => $self->render_xml,
    #    collapsed => 1,
    #    session => $repo,
    #) );
    #$frag->appendChild( $box );

    return $div;
}

sub render_external
{
    my( $self, $dataobj ) = @_;

    my $repo = $self->{repository};
  
    my $div = $repo->make_element( "div", class => "external_doi" );
    $div->appendChild( $self->html_phrase( "external_doi:title" ) );
    $div->appendChild( $self->html_phrase( "external_doi:desc" ) );

    return $div;
}

# shows a DOI already registered on datacite, what it links to, and an option to set it for this dataobj
sub render_existing
{
    my( $self, $dataobj, $datacite_data ) = @_;

    my $repo = $self->{repository};

    my $div = $repo->make_element( "div", class => "existing_doi" );
 
    $div->appendChild( $self->html_phrase( "existing_doi:title" ) );

    # show the link
    my $link = $repo->make_element( "a", href => $datacite_data->{attributes}->{url}, target => "_blank" );
    $link->appendChild( $repo->make_text( $datacite_data->{attributes}->{url} ) );
    $div->appendChild( $self->html_phrase( "existing_doi:desc", url => $link ) );

    # button to set the dataobj's doi field
    my $claim_div = $div->appendChild( $repo->make_element( "div", class => "existing_doi:claim" ) );
    my $form = $self->render_form;
 
    $form->appendChild( $repo->render_hidden_field( "claim_doi", $datacite_data->{attributes}->{doi} ) );
    $form->appendChild( $repo->render_hidden_field( "claim_class", $dataobj->get_dataset_id ) );
    $form->appendChild( $repo->render_hidden_field( "claim_dataobj", $dataobj->id ) );

    $form->appendChild( $self->{session}->render_action_buttons(
        claimdoi => $self->phrase( "existing_dois:claim_doi" ),
    ) );
    $claim_div->appendChild( $form );
   
    return $div;
}

# render a reserve button for when the doi doesn't exist anywhere on DataCite
sub render_reserve
{
    my( $self, $dataobj, $doi, $datacite_data ) = @_;
 
    my $repo = $self->{repository};

    my $div = $repo->make_element( "div", class => "reserve_doi" );

    # title
    $div->appendChild( $self->html_phrase( "reserve_doi:title" ) );

    # if the item has already been reserved show when it was reserved
    if( defined $datacite_data && $datacite_data->{attributes}->{state} eq "draft" )
    {
        $div->appendChild( $self->html_phrase( "reserve_doi:reserved",
            reserved => EPrints::Time::render_date( $repo, $datacite_data->{attributes}->{created} )
        ) );
    }
    else # show the option to reserve it
    {
        $div->appendChild( $self->html_phrase( "reserve_doi:desc" ) );

        my $form = $self->render_form( "get" );
        $form->appendChild( $repo->render_hidden_field( "reserve_doi", $doi ) );
        $form->appendChild( $repo->render_action_buttons(
            _order => [ "reservedoi" ],
            reservedoi => $self->phrase( "action:reservedoi:title" ) )
        );
        $div->appendChild( $form );
    }

    return $div;
}

# render a coin button for assigning the metadata and url for this doi. If there are any issues that would prevent this, display these instead.
sub render_coin
{
    my( $self, $dataobj, $doi, $datacite_data ) = @_;

    my $repo = $self->{repository};

    my $div = $repo->make_element( "div", class => "coin_doi" );

    # title and description
    $div->appendChild( $self->html_phrase( "coin_doi:title" ) );

    # first show any warnings
    my $problems = $self->validate( $dataobj );
    if( scalar @{$problems} > 0 )
    {
        my $coin_problems = $repo->make_element( "div", class => "coin_problems" );
        $coin_problems->appendChild( $self->html_phrase( "coin_doi:problems" ) );

        my $coin_problems_list = $coin_problems->appendChild( $repo->make_element( "ul" ) );
        foreach my $problem_xhtml ( @{$problems} )
        {
            my $li = $coin_problems_list->appendChild( $repo->make_element( "li", class => "coin_warning" ) );
            $li->appendChild( $problem_xhtml );            
        }
        $div->appendChild( $coin_problems );
    }
    # if doi is already registered and/or findable we can update it...
    elsif( defined $datacite_data && ( $datacite_data->{attributes}->{state} eq "registered" || $datacite_data->{attributes}->{state} eq "findable" ) )
    {
        my $update_doi = $repo->make_element( "div", class => "update_doi" );
        $update_doi->appendChild( $self->html_phrase( "coin_doi:update",
            registered => EPrints::Time::render_date( $repo, $datacite_data->{attributes}->{registered} ),
            updated => EPrints::Time::render_date( $repo, $datacite_data->{attributes}->{updated} ),
        ) );

        my $form = $self->render_form( "get" );
        $form->appendChild( $repo->render_hidden_field( "coin_class", $dataobj->get_dataset_id ) );
        $form->appendChild( $repo->render_hidden_field( "coin_dataobj", $dataobj->id ) );
        $form->appendChild( $repo->render_action_buttons(
            _order => [ "coindoi" ],
            coindoi => $repo->phrase( "Plugin/Screen/EPrint/Staff/CoinDOI:action:updatedoi:title" ) )
        );
        $update_doi->appendChild( $form );
        $div->appendChild( $update_doi );
    }
    else # it's a free doi and there's no problems!
    {
        my $new_doi = $repo->make_element( "div", class => "new_doi" );
        $new_doi->appendChild( $self->html_phrase( "coin_doi:new" ) );

        my $form = $self->render_form( "get" );
        $form->appendChild( $repo->render_hidden_field( "coin_class", $dataobj->get_dataset_id ) );
        $form->appendChild( $repo->render_hidden_field( "coin_dataobj", $dataobj->id ) );
        $form->appendChild( $repo->render_action_buttons(
            _order => [ "coindoi" ],
            coindoi => $repo->phrase( "Plugin/Screen/EPrint/Staff/CoinDOI:action:coindoi:title" ) )
        );
        $new_doi->appendChild( $form );
        $div->appendChild( $new_doi );
    }

    return $div;
}

# show the results of looking up this eprint's title on datacite
sub render_datacite_dois
{
    my( $self, $dataobj ) = @_;

    my $repo = $self->{repository};

    my $div = $repo->make_element( "div", class => "datacite_dois" );

    # title and description
    $div->appendChild( $self->html_phrase( "datacite_dois:title" ) );

    my $datacite_response = $self->{processor}->{datacite_response};
    if( exists $datacite_response->{results} && scalar @{$datacite_response->{results}} > 0 ) # success, show results
    {
        foreach my $result ( @{$datacite_response->{results}} )
        {
            $div->appendChild( $self->render_datacite_result( $dataobj, $result ) );
        }
    }
    elsif( exists $datacite_response->{error} ) # an actual error from the api
    {
        $div->appendChild( $self->html_phrase( "datacite_dois:error_message", code => $repo->make_text( $datacite_response->{code} ) ) );
    }
    else # no results... :(
    {
        $div->appendChild( $self->html_phrase( "datacite_dois:no_results", title => $dataobj->render_value( "title" ) ) );
    }

    return $div;
}

# show a datacite record, with a button allowing the user to select this doi for their eprint
sub render_datacite_result
{
    my( $self, $dataobj, $result ) = @_;

    my $repo = $self->{repository};

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
    $form->appendChild( $repo->render_hidden_field( "claim_doi", $result->{doi} ) );
    $form->appendChild( $repo->render_hidden_field( "claim_class", $dataobj->get_dataset_id ) );
    $form->appendChild( $repo->render_hidden_field( "claim_dataobj", $dataobj->id ) );
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
    #return 0 if($dataobj->is_set($repository->get_conf( "datacitedoi", "eprintdoifield")) && 
    #    !$repository->get_conf("datacitedoi","allow_custom_doi"));
    #TODO don't allow the coinDOI button if a DOI is already registered (may require a db flag for successful reg)
    # Or maybe check with datacite api to see if a doi is registered
    
    return $self->allow( $repository->get_conf( "datacitedoi", "minters") );
}

sub action_coindoi
{
    my( $self ) = @_;
    my $repo = $self->{repository};

    return undef if ( !defined $repo );

    # get the dataobj we want to update
    my $class = $repo->param( "coin_class" );
    my $dataset = $repo->dataset( $class );
    my $dataobj = $dataset->dataobj( $repo->param( "coin_dataobj" ) );
    return undef if ( !defined $dataobj );

    my $problems = $self->validate( $dataobj ); # double check for any problems
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
    }
    else
    {
        my $dataobj_id = $dataobj->id;
        $repo->dataset( "event_queue" )->create_dataobj({
            pluginid => "Event::DataCiteEvent",
            action => "datacite_doi",
            params => [ $dataobj->internal_uri ], # will a document have this???
        }); 

        $self->add_result_message( 1 );
    }
}    

sub allow_reservedoi { return 1; }

# reserve this eprint's DOI, i.e. add it as a draft DOI in DataCite
sub action_reservedoi
{
    my( $self ) = @_;
    my $repo = $self->{repository};

    my $doi = $repo->param( "reserve_doi" );
    return undef if ( !defined $doi );

    my $result = EPrints::DataCite::Utils::reserve_doi( $repo, $doi );
}    


sub allow_claimdoi { return 1; }

# set the doi using a previously existing one we've retrieved from DataCite
sub action_claimdoi
{
    my( $self ) = @_;
    my $repo = $self->{repository};

    return undef if ( !defined $repo );

    # get the dataobj we want to update
    my $class = $repo->param( "claim_class" );
    my $dataset = $repo->dataset( $class );
    my $dataobj = $dataset->dataobj( $repo->param( "claim_dataobj" ) );
    return undef if ( !defined $dataobj );
    
    my $doi = $repo->param( "claim_doi" );
    return undef if ( !defined $doi );

    my $doi_field = $self->{processor}->{$class.'_field'};
    $dataobj->set_value( $doi_field, $doi );
    $dataobj->commit();
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
    my( $self, $dataobj ) = @_;

    my @problems;

    my $class = $dataobj->get_dataset_id;

    my $validate_fn = "validate_datacite_$class";
    if( $self->{session}->can_call( $validate_fn ) )
    {
        push @problems, $self->{session}->call( 
            $validate_fn,
            $dataobj, 
            $self->{session}
        );
    }

    return \@problems;
}

1;
