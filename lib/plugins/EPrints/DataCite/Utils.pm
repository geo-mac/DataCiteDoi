package EPrints::DataCite::Utils;

use LWP::UserAgent;
use JSON;

use strict;

sub datacite_dois_query
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
