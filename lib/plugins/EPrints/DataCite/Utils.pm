package EPrints::DataCite::Utils;

use LWP::UserAgent;
use JSON;

use strict;

sub generate_doi
{
    my( $repository, $dataobj ) = @_;

    my $z_pad = $repository->get_conf( "datacitedoi", "zero_padding") || 0;

    my $id  = sprintf( "%0" . $z_pad . "d" , $dataobj->id );

    # Check for custom delimiters
    my( $delim1, $delim2 ) = @{$repository->get_conf( "datacitedoi", "delimiters" )};

    # default to slash
    $delim1 = "/" if( !defined $delim1 );

    # second defaults to first
    $delim2 = $delim1 if( !defined $delim2 );

    # construct the DOI string
    my $prefix = $repository->get_conf( "datacitedoi", "prefix" );
    my $thisdoi = $prefix.$delim1.$repository->get_conf( "datacitedoi", "repoid" ).$delim2.$id;
    
    return $thisdoi;    
}

# get the landing page of a single doi from the mds api
sub datacite_mds_doi
{
    my( $repo, $doi ) = @_;

    my $datacite_url = URI->new( $repo->config( 'datacitedoi', 'mdsurl' ) . "/doi/$doi" );

    my $ua = LWP::UserAgent->new();

    my $user_name = $repo->get_conf( "datacitedoi", "user" );
    my $user_pw = $repo->get_conf( "datacitedoi", "pass" );
    my $req = HTTP::Request->new( GET => $datacite_url );
    $req->authorization_basic( $user_name, $user_pw );

    my $res = $ua->request($req);
    if( $res->is_success )
    {
        return $res->content;
    }
    else
    {
        $repo->log("Error retrieving DOI from MDS API. Response code: " . $res->code . ", content: " . $res->content );
    }   
}

sub datacite_api_query
{
	my( $repo, $field, $value ) = @_;

    my %response;

    my $datacite_url = URI->new( $repo->config( 'datacitedoi', 'apiurl' ) . "/dois" );
    
    my $ua = LWP::UserAgent->new();

    $datacite_url->query_form( query => "$field:$value" );

    my $accept_header = "application/json";
    my $req_headers = HTTP::Headers->new( "Accept" => $accept_header );

    my $req = HTTP::Request->new( GET => $datacite_url, $req_headers );
    my $res = $ua->request($req);

    if( $res->is_success )
    {
        my $json = new JSON;
        $json = $json->utf8->decode( $res->content );    
        my @results;
        my $count = 0;
        my $max = $repo->config( 'datacitedoi', 'max_results' ) || 5;
        foreach my $record ( @{$json->{data}} )
        {   
            my $attributes = $record->{attributes};
            push @results, {
                title => $attributes->{titles}[0]->{title},
                date => $attributes->{publicationYear},
                publisher => $attributes->{publisher},
                url => $attributes->{url},
                doi => $attributes->{doi},
            };
            $count++;
            last if $count >= $max;
        }
        $response{results} = \@results;
        return \%response;
    }
    else
    {
        $response{error} = 1;
        $response{code} = $res->code;
        return \%response;
    }
}

1;
