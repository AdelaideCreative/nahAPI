use File::Slurp qw(slurp);
package nahAPI;
require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw($HOME nahdb nahrpc nahvalidaddr Dumper burp); 

sub Dumper;

use LWP::UserAgent;
use DBI;
use File::Slurp qw(slurp);
use JSON;
use JSON::RPC::Client;

our $HOME="/var/www/nahapi";
our $DBPW=slurp("$HOME/etc/dbpw"); chomp $DBPW;

my $ua = LWP::UserAgent->new;
$ua->timeout(10);

my %nah;
load_nah_conf();

my $client = new JSON::RPC::Client;

sub load_nah_conf {
    %nah=map {split /\s*=\s*/ unless /^\s*#/} split(/\n/,slurp("$HOME/etc/nah.conf"));
}

my @b58 = qw{
      1 2 3 4 5 6 7 8 9
    A B C D E F G H   J K L M N   P Q R S T U V W X Y Z
    a b c d e f g h i j k   m n o p q r s t u v w x y z
};
my %b58 = map { $b58[$_] => $_ } 0 .. 57;

sub service_status {
    my $stat=slurp("$HOME/etc/nah.status");
    my %r;
    for (split "\n", $stat) {
        chomp;
        next unless /([^:]+):(.*)/;
        $r{$1}=$2;
    }
    return \%r;
}
 
sub unbase58 {
    use integer;
    my @out;
    for my $c ( map { $b58{$_} } shift =~ /./g ) {
        for (my $j = 25; $j--; ) {
            $c += 58 * ($out[$j] // 0);
            $out[$j] = $c % 256;
            $c /= 256;
        }
    }
    return @out;
}

sub nahnewaddr {
    my $db=nahdb();
    my $res=nahrpc({method=>"getnewaddress"});
    return $res;
}
 
sub nahvalidaddr {
    # does nothing if the address is valid
    # dies otherwise
    
    return 0 unless $_[0]=~/^L/;
    use Digest::SHA qw(sha256);
    my @byte = unbase58 shift;

    return 0 unless
    join('', map { chr } @byte[21..24]) eq
    substr sha256(sha256 pack 'C*', @byte[0..20]), 0, 4;

    return 1;
}

sub nahrpc {
    my $rpcuri = "http://localhost:$nah{rpcport}/";
    $client->ua->credentials(
        "localhost:$nah{rpcport}", 'jsonrpc', $nah{rpcuser} => $nah{rpcpassword}
    );

    my $res = $client->call( $rpcuri, $_[0] );
    if (!$res) {
        croak $client->status_line;
    }
    if ($res->is_error) {
        croak $res->error_message;
    }
    return $res->result;
}

sub nahdb {
	return DBI->connect("DBI:Pg:dbname=nah;host=127.0.0.1", "nah", $DBPW, {'RaiseError' => 1});
}

sub Dumper {to_json(@_>1?[@_]:$_[0],{allow_nonref=>1,pretty=>1,canonical=>1,allow_blessed=>1});}

sub burp {
    my ($f, $d)=@_;
    open($t, ">$f.tmp") || die $!;
    print $t $d;
    close $t;
    rename("$f.tmp", $f);
}

sub cache_price {
    my ($coin, $cur) = @_;
    my $dat;
    my $tick="$HOME/log/cur";
    mkdir $tick;

    $coin=lc($coin);
    $cur=lc($cur);

    die unless $coin=~/nah/;
    die unless $cur=~/aud|nah/;

    $tick="$tick/$coin.$cur";

    if (((stat($tick))[9])<time()-30) {
        my $ua = LWP::UserAgent->new;
        $ua->timeout(10);
        my $res=$ua->get("https://btc-e.com/api/2/${coin}_$cur/ticker");
        if ($res->is_success) {
            $dat=from_json($res->decoded_content());
            $dat=$dat->{ticker};
            open(FILE, ">:encoding(UTF-8)", "$tick.$$");
            print FILE to_json($dat);
            close FILE;
            rename("$tick.$$", $tick);
            return $dat;
        }
    }
    return from_json(slurp($tick));
}

sub cache_ticker {
    my $dat;
    my $tick="$HOME/log/ticker";
    if (((stat($tick))[9])<time()-30) {
    # poor mans ticker...
        my $ua = LWP::UserAgent->new;
        $ua->timeout(10);
        my $res=$ua->get("https://btc-e.com/api/2/ltc_btc/ticker");
        my $btc;
        if ($res->is_success) {
            my $dat=from_json($res->decoded_content());
            $btc=$dat->{ticker}->{sell};
            if ($btc) {
                my $res=$ua->get("https://blockchain.info/ticker");
                if ($res->is_success) {
                    $dat=from_json($res->decoded_content());
                    for (keys(%$dat)) {
                        $dat->{$_}->{"15m"}*=$btc;
                        $dat->{$_}->{"24h"}*=$btc;
                        $dat->{$_}->{buy}*=$btc;
                        $dat->{$_}->{last}*=$btc;
                        $dat->{$_}->{sell}*=$btc;
                    }
                    open(FILE, ">:encoding(UTF-8)", "$tick.$$");
                    print FILE to_json($dat);
                    close FILE;
                    rename("$tick.$$", $tick);
                    return $dat;
                }
            }
        }
    }
    return from_json(slurp($tick,binmode => ':raw'));
}

1;

# vim: noai:ts=4:sw=4
