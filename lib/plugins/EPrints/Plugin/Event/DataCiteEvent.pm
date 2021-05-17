=head1 NAME

EPrints::Plugin::Event::DataCiteEvent

=cut

package EPrints::Plugin::Event::DataCiteEvent;

use EPrints::Plugin::Event;
use EPrints::DataCite::Utils;

eval "use LWP; use HTTP::Headers::Util";
eval "use WWW::Curl::Easy";

@ISA = qw( EPrints::Plugin::Event );

sub datacite_doi
{
    my( $self, $dataobj) = @_;

    my $repository = $self->repository();

    if( defined $repository->get_conf( "datacitedoi", "get_curl" ) )
    {
        # Try and import Curl.
        if ( eval "use WWW::Curl::Easy" ) { print STDERR "Unable to import WWW::Curl::Easy.\n"; }
    }
    else
    {
        # Fall back to LWP and rely in its library detection.
        if ( eval "use LWP" ) { print STDERR "Unable to import LWP.\n"; }
        if ( eval "use HTTP::Headers::Util" ) { print STDERR "Unable to import HTTP::Headers::Util.\n"; }
    }

    my $class = $dataobj->get_dataset_id;

    # Check object status first...
    my $eprint = $dataobj;
    if( $class eq "document" )
    {
        $eprint = $dataobj->get_eprint;
    }
    my $shoulddoi = $repository->get_conf( "datacitedoi", "eprintstatus",  $eprint->value( "eprint_status" ) );
    # Check Doi Status
    if( !$shoulddoi )
    {
        $repository->log("Attempt to coin DOI for item that is not in the required area (see \$c->{datacitedoi}->{eprintstatus})");
        return EPrints::Const::HTTP_INTERNAL_SERVER_ERROR;
    }

    my $thisdoi = EPrints::DataCite::Utils::generate_doi( $repository, $dataobj );

    # coin_doi may return an event error code if no prefix present assume this is the case
    my $prefix = $repository->get_conf( "datacitedoi", "prefix");
    return $thisdoi if($thisdoi !~ /^$prefix/);

    # Pass doi into Export::DataCiteXML...
    my $xml = $dataobj->export( "DataCiteXML", doi=> $thisdoi );
    return $xml if( $xml =~ /^\d+$/ ); # just a number? coin_doi has passed back an error code pass it on...

    #print STDERR "XML: $xml\n";
    my $url = $repository->get_conf( "datacitedoi", "mdsurl" );
    $url.="/" if( $url !~ /\/$/ ); # attach slash if config has forgotten
    my $user_name = $repository->get_conf( "datacitedoi", "user" );
    my $user_pw = $repository->get_conf( "datacitedoi", "pass" );

    # register metadata;
    my $response_content;
    my $response_code;
    # Test if we want to be using curl; if we don't run the 'old' LWP code
    if( defined $repository->get_conf( "datacitedoi", "get_curl" ) )
    {
        ( $response_content, $response_code ) =  datacite_request_curl( $url."metadata", $user_name, $user_pw, $xml, "application/xml;charset=UTF-8" );
    }
    else
    {
        ( $response_content, $response_code ) =  datacite_request( "POST", $url."metadata", $user_name, $user_pw, $xml, "application/xml;charset=UTF-8" );
    }

    if( $response_code !~ /20(1|0)/ )
    {
        $repository->log( "Metadata response from datacite api when submitting $class $dataobj->id: $response_code: $response_content" );
        $repository->log( "XML submitted was:\n$xml" );
        return EPrints::Const::HTTP_INTERNAL_SERVER_ERROR;
    }
    
    # register doi
    my $repo_url =$dataobj->uri();
    # RM special override to allow testing from "wrong" domain
    if( defined $repository->get_conf( "datacitedoi", "override_url" ) )
    {
        $repo_url = $repository->get_conf( "datacitedoi", "override_url" );
        $repo_url.= $dataobj->internal_uri;
    }
    my $doi_reg = "doi=$thisdoi\nurl=".$repo_url;
    # Test if we want to be using curl; if we don't run the 'old' LWP code
    if( defined $repository->get_conf( "datacitedoi", "get_curl" ) )
    {
        ( $response_content, $response_code )= datacite_request_curl( $url."doi", $user_name, $user_pw, $doi_reg, "text/plain; charset=utf8" );
    }
    else
    {
        ( $response_content, $response_code )= datacite_request("POST", $url."doi", $user_name, $user_pw, $doi_reg, "text/plain; charset=utf8" );
    }
    if( $response_code  !~ /20(1|0)/ )
    {
        $repository->log("Registration response from datacite api: $response_code: $response_content");
        $repository->log("XML submitted was:\n$xml");
        return EPrints::Const::HTTP_INTERNAL_SERVER_ERROR;
    }

    # now it is safe to set DOI value.
    my $doifield = $repository->get_conf( "datacitedoi", $class."doifield" ); 
    $dataobj->set_value( $doifield, $thisdoi );
    $dataobj->commit();
    # success
    return undef;
}


sub datacite_request
{
    my( $method, $url, $user_name, $user_pw, $content, $content_type ) = @_;

    # build request
    my $headers = HTTP::Headers->new(
        'Accept'  => 'application/xml',
        'Content-Type' => $content_type
    );

    my $req = HTTP::Request->new(
        $method => $url,
        $headers, Encode::encode_utf8( $content )
    );
    $req->authorization_basic($user_name, $user_pw);

    # pass request to the user agent and get a response back
    my $ua = LWP::UserAgent->new;
    my $res = $ua->request($req);

    return ($res->content(),$res->code());
}

sub datacite_request_curl
{
    my( $url, $user_name, $user_pw, $content, $content_type ) = @_;

    # build request
    my @myheaders = (
        "Accept: application/xml",
        "Content-Type: $content_type"
    );
    
    my $curl = new WWW::Curl::Easy;

    $curl->setopt(CURLOPT_FAILONERROR,1);
    # $curl->setopt(CURLOPT_HEADER,1);
    # $curl->setopt(CURLOPT_VERBOSE, 1);
    $curl->setopt(CURLOPT_POST, 1);
    $curl->setopt(CURLOPT_URL, $url);
    $curl->setopt(CURLOPT_USERNAME, $user_name);
    $curl->setopt(CURLOPT_PASSWORD, $user_pw);
    $curl->setopt(CURLOPT_POSTFIELDS, $content);
    $curl->setopt(CURLOPT_HTTPHEADER, \@myheaders);

    my $response_body;
    open( my $fileb, ">", \$response_body );
    $curl->setopt(CURLOPT_WRITEDATA,$fileb);


    # pass request and get a response back
    my $retcode = $curl->perform;

    # Use response to determine HTTP status code
    $http_retcode    = $curl->getinfo(CURLINFO_HTTP_CODE);

#   # Ensure we return a useful (well, usable) message and error response
#   if ($retcode == 0) {
#     $content = "Received response: $response_body\n";
#   } else {
#     $http_prose = $curl->strerror($retcode);
#     $content = "An error happened: $http_prose $http_retcode (Curl error code $retcode)\n";
#   }

    return ($content, $http_retcode);
}


sub datacite_update_doi
{
    my( $self, $eprint, $new_status ) = @_;
    
    my $repo = $self->repository;

    my $eprint_doi = EPrints::DataCite::Utils::generate_doi( $repo, $eprint );
    my $eprint_id = $eprint->id;

    # is there a record of this DOI on DataCite?
    my $datacite_doi = EPrints::DataCite::Utils::datacite_doi_query( $repo, $eprint_doi );
    if( !defined $datacite_doi )
    {
        $repo->log( "DOI not found on DataCite, no record to update (EPrint: $eprint_id, DOI: $eprint_doi)" );
        return EPrints::Const::HTTP_NOT_FOUND;
    }

    # if this is a draft doi, there's no point worrying about it
    if( $datacite_doi->{data}->{attributes}->{state} eq "draft" )
    {
        $repo->log( "DOI exists only in a draft state on DataCite (EPrint: $eprint_id, DOI: $eprint_doi)" );
        return EPrints::Const::HTTP_NOT_FOUND;
    }

    my $user_name = $repo->get_conf( "datacitedoi", "user" );
    my $user_pw = $repo->get_conf( "datacitedoi", "pass" );
    my $datacite_url = URI->new( $repo->config( 'datacitedoi', 'mdsurl' ) . "/metadata/$eprint_doi" );
    my $ua = LWP::UserAgent->new();
    my $req;

    # if our new status is retired and on datacite we're findable... set as registered
    if( $new_status eq "deletion" && $datacite_doi->{data}->{attributes}->{state} eq "findable" )
    {
        # set to registered with a DELETE request
        $req = HTTP::Request->new( DELETE => $datacite_url );       
    }
    # if our new status is archive, and we're registered... set as findable
    
    if( $new_status eq "archive" && $datacite_doi->{data}->{attributes}->{state} eq "registered" )
    {
        # set to findable with a PUT request
        $req = HTTP::Request->new( PUT => $datacite_url );       
    }

    # oddly, despite our previous checks, neither of the previous two conditions were true, so nothing happens...
    if( !defined $req )
    {
        $repo->log( "No update applied to DOI: $eprint_doi (EPrint: $eprint_id)" );
        return EPrints::Const::HTTP_INTERNAL_SERVER_ERROR;
    }

    $req->authorization_basic( $user_name, $user_pw );
    my $res = $ua->request( $req );
    if( $res->is_success )
    {
        $repo->log( "DOI successfully updated following EPrint $eprint_id status update to '$new_status' (DOI: $eprint_doi)" );
        return EPrints::Const::HTTP_OK;
    }
    else
    {
        $repo->log("DataCite API error following EPrint $eprint_id status update to '$new_status'. Response code: " . $res->code . ", content: " . $res->content );
        return EPrints::Const::HTTP_INTERNAL_SERVER_ERROR;
    }
}

1;
