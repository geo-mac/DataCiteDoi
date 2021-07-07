package EPrints::Plugin::Screen::EPrint::Staff::CoinDOI;

#use EPrints::Plugin::Screen::EPrint;

use EPrints::DataCite::Utils;
use Data::Dumper;

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

    # get the fields where we would store dois
    my $eprint_doi_field = $repo->get_conf( "datacitedoi", "eprintdoifield" );
    my $document_doi_field = $repo->get_conf( "datacitedoi", "documentdoifield" );

    $self->{processor}->{eprint_field} = $eprint_doi_field;
    $self->{processor}->{document_field} = $document_doi_field;

    ## EPrint DOI data
    $self->{processor}->{dois}->{eprint}->{$eprint_id} = $self->get_doi_info( $repo, $eprint, $eprint_doi_field );

    # check to see if this eprint is a later version of an existing eprint
    if( $eprint->is_set( "succeeds" ) )
    {
        my $ds = $eprint->dataset;
        my $parent = $ds->dataobj( $eprint->value( "succeeds" ) );          
        if( defined $parent )
        {
            my $parent_id = $parent->id;
            $self->{processor}->{dois}->{eprint}->{$parent_id} = $self->get_doi_info( $repo, $parent, $eprint_doi_field );

            if( $self->{processor}->{dois}->{eprint}->{$eprint_id}->{current_doi}->{url} eq $parent->uri )
            {
                $self->{processor}->{dois}->{eprint}->{$eprint_id}->{current_doi}->{redirects_to_parent} = 1;
            }

        }
    }

    ## Document DOI data
    # only check for existing document dois if this repository can coin doc dois and present landing pages for them
    if( $repo->get_conf( "datacitedoi", "document_dois" ) )
    {
        foreach my $doc ( $eprint->get_all_documents )
        {
            my $doc_id = $doc->id;
            $self->{processor}->{dois}->{document}->{$doc_id} = $self->get_doi_info( $repo, $doc, $document_doi_field ); 
        }
    }

    #print STDERR "DOIs....\n";
    #print STDERR Dumper( $self->{processor}->{dois} );

    # DataCite title query to look for any DOIs that might already represent this record
    if( !$eprint->is_set( $eprint_doi_field ) )
    {
        $self->{processor}->{datacite_response} = EPrints::DataCite::Utils::datacite_api_query( $repo, "titles.title", $eprint->value( "title" ) );
    }
}

sub get_doi_info
{
    my( $self, $repo, $dataobj, $doi_field ) = @_;

    my $data = {};

    # get the DOI that would be generated for this eprint
    my $generated_doi = EPrints::DataCite::Utils::generate_doi( $repo, $dataobj );

    # Does the DOI that would be generated for this record already exist, either in draft form of some other form
    my $datacite_data = EPrints::DataCite::Utils::datacite_doi_query( $repo, $generated_doi );

    # store state
    if( defined $datacite_data )
    {
        $data->{generated_doi} = $self->process_datacite_response( $repo, $dataobj, $datacite_data );
    }
    else
    {
         $data->{generated_doi}->{state} = "available"; # not an official DataCite state, used to say we can coin
    }

    # finally, store the generated DOI
    $data->{generated_doi}->{doi} = $generated_doi;

    # store the current DOI
    if( $dataobj->is_set( $doi_field ) )
    {        
        my $current_doi = $dataobj->value( $doi_field );
     
        # check the DOI with DataCite       
        my $datacite_data = EPrints::DataCite::Utils::datacite_doi_query( $repo, $current_doi );

        # we have a response from DataCite for our stored DOI
        if( defined $datacite_data )
        {
             $data->{current_doi} = $self->process_datacite_response( $repo, $dataobj, $datacite_data );
        }
        # no response from DataCite, but this DOI is the same as the one we would coin
        elsif( lc( $current_doi ) eq lc( $generated_doi ) ) 
        {
            $data->{current_doi}->{state} = "available"; # not an official DataCite state, used to say we can coin
        }
        # no response and we don't know what to do with the DOI, probably not one of ours
        else
        {
            $data->{current_doi}->{state} = "unavailable"; # not an official DataCite state, used to say nothing we can do
        }

        # finally, store the current DOI
        $data->{current_doi}->{doi} = $current_doi;
    }
    return $data;
}

# gets all the data we might need from a datacite DOI query response
sub process_datacite_response
{
    my( $self, $repo, $dataobj, $datacite_data ) = @_;

    my $data = {};

    # first get the state
    my $state = $datacite_data->{data}->{attributes}->{state};
    $data->{state} = $state;

    if( $state eq "draft" )
    {
        $data->{created} = $datacite_data->{data}->{attributes}->{created};
    }
    elsif( $state eq "registered" || $state eq "findable" )
    {
        # get timestamps
        $data->{registered} = $datacite_data->{data}->{attributes}->{registered};
        $data->{updated} = $datacite_data->{data}->{attributes}->{updated};

        # get the url
        $data->{url} = $datacite_data->{data}->{attributes}->{url};   
 
        # does it point to us?
        if( $datacite_data->{data}->{attributes}->{url} eq $dataobj->uri )
        {
            $data->{redirects_to_dataobj} = 1;   
        }

        # can the repository update it?
        my $username = $repo->get_conf( "datacitedoi", "user" );
        if( lc( $datacite_data->{data}->{relationships}->{client}->{data}->{id} ) eq lc( $username ) )
        {
            $data->{repo_doi} = 1;   
        }
    }

    return $data;
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
    my $generated_doi = EPrints::DataCite::Utils::generate_doi( $repo, $dataobj );

    my $datacite_data;
    $datacite_data = $self->{processor}->{$class}->{$dataobj_id}->{datacite_data} if exists $self->{processor}->{$class}->{$dataobj_id};

    ### start rendering
    my $div = $repo->make_element( "div", class => "datacite_object datacite_$class" );

    ## display basic info about the dataobj
    my $info_div = $div->appendChild( $repo->make_element( "div", class => "datacite_dataobj_info datacite_section" ) );

    # dataobj citation
    my $citation_div = $info_div->appendChild( $repo->make_element( "div", class => "datacite_citation" ) );
    if( $class eq "eprint" )
    {
        $citation_div->appendChild( $dataobj->render_citation_link );
    }
    elsif( $class eq "document" )
    {
        $citation_div->appendChild( $self->render_document_citation( $dataobj ) );
    }

    ## Potential problems
    my $problems = $self->validate( $dataobj );
    my $disable_updates = 0;
    if( scalar @{$problems} > 0 )
    {
        $disable_updates = 1;

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

    ## DOI options
    if( $dataobj->is_set( $doi_field ) )
    {
        $div->appendChild( $self->render_current_doi( $dataobj, $doi_field, $self->{processor}->{dois}->{$class}->{$dataobj_id}, $disable_updates ) );
    }

    if( !$dataobj->is_set( $doi_field ) || lc( $dataobj->value( $doi_field ) ) ne lc( $generated_doi ) )
    {
        $div->appendChild( $self->render_available_doi( $dataobj, $doi_field, $self->{processor}->{dois}->{$class}->{$dataobj_id}, $disable_updates ) );

    }

    # if we're an eprint we might be able to find potential dois in datacite
    if( $class eq "eprint" && !$dataobj->is_set( $doi_field ) )
    {
        $div->appendChild( $self->render_datacite_dois( $dataobj ) );
    }

    # DataCite XML
    if( $repo->get_conf( "datacitedoi", "show_xml" ) )
    {
        my $box = $repo->make_element( "div", class => "datacite_xml" );
        $box->appendChild( EPrints::Box::render(
            id => "datacite_xml_".$class."_".$dataobj_id,
            title => $self->html_phrase( "data:title" ),
            content => $self->render_xml( $dataobj ),
            collapsed => 1,
            session => $repo,
        ) );
        $div->appendChild( $box );
    }

    return $div;
}

sub render_document_citation
{
    my( $self, $doc ) = @_;

    my $repo = $self->{repository};
  
    my $div = $repo->make_element( "div", class => "datacite_doc_citation" );
    
    my $table = $div->appendChild( $repo->make_element( "div", class => "ep_table" ) );
    my $tr = $table->appendChild( $repo->make_element( "div", class => "ep_table_row" ) );

    my $icon = $tr->appendChild( $repo->make_element( "div", class => "ep_table_cell" ) );
    $icon->appendChild( $doc->render_icon_link );

    my $citation = $tr->appendChild( $repo->make_element( "div", class => "ep_table_cell" ) );
    $citation->appendChild( $doc->render_citation_link );

    return $div;
}

# Display information and options about the DOI currently associated with the record
sub render_current_doi
{
    my( $self, $dataobj, $doi_field, $doi_info, $disable_updates ) = @_;

    my $repo = $self->{repository};

    my $div = $repo->make_element( "div", class => "current_doi datacite_section" );
 
    ## title
    my $title_div = $div->appendChild( $repo->make_element( "div", class => "datacite_title" ) );
    $title_div->appendChild( $self->html_phrase( "current_doi:title" ) );

    my $doi_table = $div->appendChild( $repo->make_element( "div", class => "ep_table" ) );

    ## DOI    
    my $doi_row = $doi_table->appendChild( $repo->make_element( "div", class => "ep_table_row" ) );
    my $doi_title = $doi_row->appendChild( $repo->make_element( "div", class => "ep_table_cell" ) );
    $doi_title->appendChild( $self->html_phrase( "current_doi:doi" ) );
    my $doi_value = $doi_row->appendChild( $repo->make_element( "div", class => "ep_table_cell" ) );
    $doi_value->appendChild( $dataobj->render_value( $doi_field ) );

    ## Redirects to
    my $redirect_row = $doi_table->appendChild( $repo->make_element( "div", class => "ep_table_row" ) );
    my $redirect_title = $redirect_row->appendChild( $repo->make_element( "div", class => "ep_table_cell" ) );
    $redirect_title->appendChild( $self->html_phrase( "current_doi:redirect" ) );
    my $redirect_value = $redirect_row->appendChild( $repo->make_element( "div", class => "ep_table_cell" ) );

    # Redirect options...
    # Redirects to self
    if( defined $doi_info->{current_doi}->{redirects_to_dataobj} )
    {
        my $link = $repo->make_element( "a", href => $doi_info->{current_doi}->{url}, target => "_blank" );
        $link->appendChild( $repo->make_text( $doi_info->{current_doi}->{url} ) );
        $redirect_value->appendChild( $self->html_phrase( "current_doi:redirect:self", url => $link ) );
    }
    # Redirects to known DataCite URL
    elsif( defined $doi_info->{current_doi}->{url} )
    {
        my $link = $repo->make_element( "a", href => $doi_info->{current_doi}->{url}, target => "_blank" );
        $link->appendChild( $repo->make_text( $doi_info->{current_doi}->{url} ) );
     
        # Redirects to parent EPrint
        if( defined $doi_info->{current_doi}->{redirects_to_parent} )
        {
            $redirect_value->appendChild( $self->html_phrase( "current_doi:redirect:parent", url => $link ) );
        }
        else
        {             
            $redirect_value->appendChild( $link );
        }
    }
    else
    {
        $redirect_value->appendChild( $dataobj->render_value( $doi_field ) );
    }

    ## Update
    unless( $disable_updates )
    {
        # We can update and it already points to us => Just update metadata
        if( defined $doi_info->{current_doi}->{repo_doi} && defined $doi_info->{current_doi}->{redirects_to_dataobj} )
        {
            $doi_table->appendChild( $self->render_update_row(
                $repo,
                $dataobj,
                "metadata_only",
                $doi_info->{current_doi}->{doi},
                $doi_info->{current_doi}->{registered},
                $doi_info->{current_doi}->{updated},
            ) );
        }
        # We can update, but it points elsewhere => Update and redirect to us
        elsif( defined $doi_info->{current_doi}->{repo_doi} )
        {
            $doi_table->appendChild( $self->render_update_row(
                $repo,
                $dataobj,
                "url",
                $doi_info->{current_doi}->{doi},
                $doi_info->{current_doi}->{registered},
                $doi_info->{current_doi}->{updated},
            ) );
        }
    }

    ## if current DOI is the one we would generate, we might be able to reserve it or coin a new DOI
    if( lc( $doi_info->{current_doi}->{doi} ) eq lc( $doi_info->{generated_doi}->{doi} ) )
    {
        ## Reserve
        if( $doi_info->{current_doi}->{state} eq "available" || $doi_info->{current_doi}->{state} eq "draft" )
        {
            $doi_table->appendChild( $self->render_reserve_row(
                $repo,
                $doi_info->{current_doi},
            ) );
        }

        unless( $disable_updates )
        {
            ## Coin
            if( $doi_info->{current_doi}->{state} eq "available" || $doi_info->{current_doi}->{state} eq "draft" )
            {
                $doi_table->appendChild( $self->render_update_row( 
                    $repo,
                    $dataobj,
                    "coin",
                ) );
            }
        }
    }
    return $div;
}

# Display information and options about a DOI that is available/reserved for this record
sub render_available_doi
{
    my( $self, $dataobj, $doi_field, $doi_info, $disable_updates ) = @_;
    
    my $repo = $self->{repository};

    my $div = $repo->make_element( "div", class => "available_doi datacite_section" );
 
    ## title
    my $title_div = $div->appendChild( $repo->make_element( "div", class => "datacite_title" ) );
    $title_div->appendChild( $self->html_phrase( "available_doi:title" ) );

    ## show alert if dataobj already has a DOI (we don't want to coin an unnecessary one just because we can)
    if( $dataobj->is_set( $doi_field ) )
    {
        my $alert_div = $div->appendChild( $repo->make_element( "div", class => "datacite_alert" ) );
        $alert_div->appendChild( $self->html_phrase( "available_doi:alert" ) );
    }

    my $doi_table = $div->appendChild( $repo->make_element( "div", class => "ep_table" ) );

    ## DOI    
    my $doi_row = $doi_table->appendChild( $repo->make_element( "div", class => "ep_table_row" ) );
    my $doi_title = $doi_row->appendChild( $repo->make_element( "div", class => "ep_table_cell" ) );
    $doi_title->appendChild( $self->html_phrase( "available_doi:doi" ) );
    my $doi_value = $doi_row->appendChild( $repo->make_element( "div", class => "ep_table_cell" ) );
    $doi_value->appendChild( $repo->make_text( $doi_info->{generated_doi}->{doi} ) );

    ## Reserve
    if( $doi_info->{generated_doi}->{state} eq "available" || $doi_info->{generated_doi}->{state} eq "draft" )
    {
        $doi_table->appendChild( $self->render_reserve_row(
            $repo,
            $doi_info->{generated_doi},
        ) );
    }

    unless( $disable_updates )
    {
        ## Coin
        if( $doi_info->{generated_doi}->{state} eq "available" || $doi_info->{generated_doi}->{state} eq "draft" )
        {
            $doi_table->appendChild( $self->render_update_row( 
                $repo,
                $dataobj,
                "coin",
            ) );
        }

        ## Claim - for DOIs already coined
        if( $doi_info->{generated_doi}->{state} eq "findable" || $doi_info->{generated_doi}->{state} eq "registered" )
        {
             $doi_table->appendChild( $self->render_update_row( 
                $repo,
                $dataobj,
                "claim",
                $doi_info->{generated_doi}->{doi},
                $doi_info->{generated_doi}->{registered},
                $doi_info->{generated_doi}->{updated},
            ) );
        }
    }

    return $div;
}

# Form and details for updating an existing DOI
# $mode = coin              => Coin a brand new DOI
# $mode = metadata_only     => Metadata update only
# $mode = url               => Metadata and URL redirect updated
# $mode = claim             => For DataObjs not associated with their registered/findable DOI
sub render_update_row
{
    my( $self, $repo, $dataobj, $mode, $doi, $registered, $updated ) = @_;

    my $update_row = $repo->make_element( "div", class => "ep_table_row" );
    my $update_title = $update_row->appendChild( $repo->make_element( "div", class => "ep_table_cell" ) );
    $update_title->appendChild( $self->html_phrase( "update_doi:$mode" ) );
    my $update_value = $update_row->appendChild( $repo->make_element( "div", class => "ep_table_cell" ) );

    # details on when the DOI was registered and updated
    if( defined $registered && defined $updated )
    {
        $update_value->appendChild( $self->html_phrase( "update_doi:timestamps",
            registered => EPrints::Time::render_date( $repo, $registered ),
            updated => EPrints::Time::render_date( $repo, $updated ),
        ) );
    }   
   
    my $form = $update_value->appendChild( $self->render_form( "get" ) );
    $form->appendChild( $repo->render_hidden_field( "coin_class", $dataobj->get_dataset_id ) );
    $form->appendChild( $repo->render_hidden_field( "coin_dataobj", $dataobj->id ) );

    # include the DOI if we're updating an existing DOI
    $form->appendChild( $repo->render_hidden_field( "coin_doi", $doi ) ) if( defined $doi );

    $form->appendChild( $repo->render_action_buttons(
        _order => [ "coindoi" ],
        coindoi => $repo->phrase( "Plugin/Screen/EPrint/Staff/CoinDOI:action:coin:".$mode.":title" ) )
    );

    return $update_row;
}

# Render Reserve options or details
sub render_reserve_row
{
    my( $self, $repo, $doi_info ) = @_;

    my $reserve_row = $repo->make_element( "div", class => "ep_table_row" );
    my $reserve_title = $reserve_row->appendChild( $repo->make_element( "div", class => "ep_table_cell" ) );
    $reserve_title->appendChild( $self->html_phrase( "reserve_doi:title" ) );
    my $reserve_value = $reserve_row->appendChild( $repo->make_element( "div", class => "ep_table_cell" ) );

    if( defined $doi_info->{created} )
    {
        $reserve_value->appendChild( $self->html_phrase( "reserve_doi:reserved",
            reserved => EPrints::Time::render_date( $repo, $doi_info->{created} )
        ) );
    }
    else
    {
        $reserve_value->appendChild( $self->html_phrase( "reserve_doi:desc" ) );

        my $form = $reserve_value->appendChild( $self->render_form( "get" ) );
        $form->appendChild( $repo->render_hidden_field( "reserve_doi", $doi_info->{doi} ) );
        $form->appendChild( $repo->render_action_buttons(
            _order => [ "reservedoi" ],
            reservedoi => $self->phrase( "action:reservedoi:title" ) )
        );
    }
    return $reserve_row;
}

# show the results of looking up this eprint's title on datacite
sub render_datacite_dois
{
    my( $self, $dataobj ) = @_;

    my $repo = $self->{repository};

    my $div = $repo->make_element( "div", class => "datacite_dois datacite_section" );

    # title
    my $title_div = $div->appendChild( $repo->make_element( "div", class => "datacite_title" ) );
    $title_div->appendChild( $self->html_phrase( "datacite_dois:title" ) );

    my $datacite_response = $self->{processor}->{datacite_response};
    if( exists $datacite_response->{results} && scalar @{$datacite_response->{results}} > 0 ) # success, show results
    {
        my $results_div = $div->appendChild( $repo->make_element( "div", class => "datacite_results" ) );

        foreach my $result ( @{$datacite_response->{results}} )
        {
            $results_div->appendChild( $self->render_datacite_result( $dataobj, $result ) );
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
    my( $self, $dataobj ) = @_;

    my $repo = $self->{repository};

    my $pre = $repo->make_element( "pre" );

    my $xml = $dataobj->export( "DataCiteXML" );
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

    # we might be updating an existing DOI, so get that if available
    my $doi = $repo->param( "coin_doi" );

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
            params => [ $dataobj->internal_uri, $doi ], # will a document have this???
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
