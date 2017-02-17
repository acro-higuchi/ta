package Text::TogoAnnotator;

# Yasunori Yamamoto / Database Center for Life Science
# -- 変更履歴 --
# * 2013.11.28 辞書ファイル仕様変更による。
# 市川さん>宮澤さんの後任が記載するルールを変えたので、正解データとしてngram掛けるのは、第3タブが○になっているもの、だけではなく、「delとRNA以外」としてください。
# * 2013.12.19 前後の"の有無の他に、出典を示す[nite]的な文字の後に"があるものと前に"があるものがあって全てに対応していなかったことに対応。
# * 2014.06.12 モジュール化
# getScore関数内で//オペレーターを使用しているため、Perlバージョンが5.10以降である必要がある。
# * 2014.09.19 14/7/23 リクエストに対応
# 1. 既に正解辞書に完全一致するエントリーがある場合は、そのままにする。
# 2. "subunit", "domain protein", "family protein" などがあり、辞書中にエントリーが無い場合は、そのままにする。
# * 2014.11.6
# 「辞書で"del"が付いているものは、人の目で確認することが望ましいという意味です。」とのコメントを受け、出力で明示するようにした。
# 具体的には、result:$query, match:"del", info:"Human check preferable" が返る。
# ハイフンの有無だけでなく空白の有無も問題を生じさせうるので、全ての空白を取り除く処理を加えてみた。
# * 2014.11.7
# Bag::Similarity::Cosineモジュールの利用で実際のcosine距離を取得してみる。
# なお、simstringには距離を取得する機能はない。
# n-gramの値はsimstringと同じ値を適用。
# "fragment"をavoid_cs_termsに追加。
# * 2014.11.21
# スコアの並び替えについては、クエリ中の語が含まれる候補を優先し、続いてcosine距離を考慮する方針に変更。
# * 2016.3.16
# exもしくはcsの際の結果のみを配列に含むresult_arrayを追加。
# * 2016.5.10
# 辞書にg列（curated）とh列（note）があることを想定した修正。
# 辞書ファイルの名前が.gzで終る場合は、gzip圧縮されたファイルとして扱い、展開する仕様に変更。
# * 2016.7.8
# Before -> After、After -> Curated ではなく、Curated辞書の書き換え前エントリをTogoAnnotator辞書のBeforeに含めて、それを優先されるようにする（完全一致のみ）。
# https://bitbucket.org/yayamamo/togoannotator/issues/3/curated
# なお、マッチさせるときには大文字小文字の違いを無視する。
# * 2016.10.13
# 酵素名辞書とマッチするデフィニションは優先順位を高めるようにした。
# 英語表記を米語表記に変換するようにした。
# * 2016.10.28
# Locus tagのプレフィックスか、EMBLから取得したLocus tagにマッチする場合には、その旨infoに記述する仕様に変更。
# * 2016.12.22
# UniProtのReviewed=trueであるタンパク質エントリのencodedByで結ばれる遺伝子のprefLabelを利用し、それに入力された文字がマッチした場合にはその旨infoに記述する仕様に変更。
# Pfamのファミリーネームに入力された文字列がマッチした場合にはその旨infoに記述する仕様に変更。
# * 2017.1.31
# After -> Curated については実装から削除。Queryが与えられたら、それがCuratedのBeforeにマッチするか見て適宜書き換えるのみとする。
# After -> Curated の部分については利用者がカスタム辞書を用意することで対応する方針とする。
# 既に辞書の内部利用ファイルが作られている場合にはそれを利用できるようにした。$useCurrentDictで与える。
# 内部辞書構築にはmkDictionary.pl を用いる。
# * 2017.2.17
# MySQLを用いて各種辞書にアクセスする方式に変更。

use warnings;
use strict;
use Fatal qw/open/;
use File::Path 'mkpath';
use File::Basename;
#use File::Slurp qw(read_file write_file);
use Bag::Similarity::Cosine;
use String::Trim;
use simstring;
use PerlIO::gzip;
use Lingua::EN::ABC qw/b2a/;
#use Text::Match::FastAlternatives;
use JSON::XS;
use utf8;
use DBI;
use Digest::MD5 qw/md5_hex/;
use Data::Dumper;

my ($sysroot, $niteAll, $curatedDict, $enzymeDict, $locustag_prefix_name, $embl_locustag_name, $gene_symbol_name, $family_name);
my ($nitealldb_after_name, $nitealldb_before_name);
my ($niteall_after_cs_db, $niteall_before_cs_db);
my ($cos_threshold, $e_threashold, $cs_max, $n_gram, $cosine_object, $ignore_chars, $locustag_prefix_matcher, $embl_locustag_matcher, $gene_symbol_matcher, $family_name_matcher);
my $useCurrentDict;
my ($dbh, $r_conv, $r_convE, $r_convD, $r_cd, $md5dname);
my ($r_locus_tag_prefix, $r_embl2locus_tag, $r_gene_symbol, $r_family_name);

my (
    @sp_words, # マッチ対象から外すが、マッチ処理後は元に戻して結果に表示させる語群。
    @avoid_cs_terms # コサイン距離を用いた類似マッチの対象にはしない文字列群。種々の辞書に完全一致しない場合はno_hitとする。
    );
my (
    %correct_definitions, # マッチ用内部辞書には全エントリが小文字化されて入るが、同じく小文字化したクエリが完全一致した場合には辞書に既にあるとして処理する。
    %histogram,
    %convtable,           # 書換辞書の書換前後の対応表。小文字化したクエリが、同じく小文字化した書換え前の語に一致した場合は対応する書換後の語を一致させて出力する。
    %negative_min_words,  # コサイン距離を用いた類似マッチではクエリと辞書中のエントリで文字列としては類似していても、両者の間に共通に出現する語が無い場合がある。
    # その場合、共通に出現する語がある辞書中エントリを優先させる処理をしているが、本処理が逆効果となってしまう語がここに含まれる。
    %wospconvtableD, %wospconvtableE, # 全空白文字除去前後の対応表。書換え前と後用それぞれ。
    #%name_provenance,     # 変換後デフィニションの由来。
    %curatedHash,         # curated辞書のエントリ（キーは小文字化する）
    %enzymeHash           # 酵素辞書のエントリ（小文字化する）
    );
my ($minfreq, $minword, $ifhit, $cosdist);

sub init {
    my $_this = shift;
    $cos_threshold = shift; # cosine距離で類似度を測る際に用いる閾値。この値以上類似している場合は変換対象の候補とする。
    $e_threashold  = shift; # E列での表現から候補を探す場合、辞書中での最大出現頻度がここで指定する数未満の場合のもののみを対象とする。
    $cs_max        = shift; # 複数表示する候補が在る場合の最大表示数
    $n_gram        = shift; # N-gram
    $sysroot       = shift; # 辞書や作業用ファイルを生成するディレクトリ
    $niteAll       = shift; # 辞書名
    $curatedDict   = shift; # curated辞書名（形式は同一）
    $useCurrentDict= shift; # 既に内部利用辞書ファイルがある場合には、それを削除して改めて構築するか否か

    $enzymeDict = "enzyme/enzyme_accepted_names.txt";
    $locustag_prefix_name = "locus_tag_prefix.txt";
    $embl_locustag_name = "uniprot_evaluation/Embl2LocusTag.txt";
    $gene_symbol_name = "UniProtPrefGeneSymbols.txt";
    $family_name = "pfam-ac.txt";

    @sp_words = qw/putative probable possible/;
    @avoid_cs_terms = (
	"subunit",
	"domain protein",
	"family protein",
	"-like protein",
	"fragment",
	);
    for ( @avoid_cs_terms ){
	s/[^\w\s]//g;
	do {$negative_min_words{$_} = 1} for split " ";
    }

    # 未定議の場合の初期値
    $cos_threshold //= 0.6;
    $e_threashold //= 30;
    $cs_max //= 5;
    $n_gram //= 3;
    $ignore_chars = qr{[-/,:+()]};

    $cosine_object = Bag::Similarity::Cosine->new;

    $dbh = DBI->connect( "dbi:mysql:TogoAnnotator;localhost;mysql_socket=/opt/services/togoannot/local/mysql/mysql.sock",
			 "yayamamo", "yayamamo",  { RaiseError => 1, AutoCommit => 1, PrintWarn => 1}) or die "$!\n";
    readDict();
}

=head
類似度計算用辞書およびマッチ（完全一致）用辞書の構築
  類似度計算は simstring
    類似度計算用辞書の見出し語は全て空白文字を除去し、小文字化したもの
    書換前後の語群それぞれを独立した辞書にしている
  完全一致はハッシュ
    ハッシュは書換用辞書とキュレーテッド
    更に書換用辞書についてはconvtableとcorrect_definition
    convtableのキーは書換前の語に対して特殊文字を除去し、小文字化したもの
    convtableの値は書換後の語
    correct_definitionのキーは書換後の語に対して特殊文字を除去し、小文字化したもの
    correct_definitionの値は書換後の語
=cut

sub readDict {
    # 類似度計算用辞書構築の準備
    (my $dname = basename $niteAll) =~ s/\..*$//;
    my $dictdir = 'dictionary/'.$dname;
    $md5dname = md5_hex($dname);

    my $niteall_after_db;
    my $niteall_before_db;

    $nitealldb_after_name = $sysroot.'/'.$dictdir.'/after';   # After
    $nitealldb_before_name = $sysroot.'/'.$dictdir.'/before'; # Before

    unless( $useCurrentDict ){
	if (!-d  $sysroot.'/'.$dictdir){
	    mkpath($sysroot.'/'.$dictdir);
	}

	for my $f ( <${sysroot}/${dictdir}/after*> ){
	    unlink $f;
	}
	for my $f ( <${sysroot}/${dictdir}/before*> ){
	    unlink $f;
	}

	$niteall_after_db = simstring::writer->new($nitealldb_after_name, $n_gram);
	$niteall_before_db = simstring::writer->new($nitealldb_before_name, $n_gram);
    }

    my @hash_pack;

    # キュレーテッド辞書の構築
    if($curatedDict){
	open(my $curated_dict, $sysroot.'/'.$curatedDict);
	while(<$curated_dict>){
	    chomp;
	    my (undef, undef, undef, undef, $name, undef, $curated, $note) = split /\t/;
	    $name //= "";
	    trim( $name );
	    trim( $curated );
	    $name =~ s/^"\s*//;
	    $name =~ s/\s*"$//;
	    $curated =~ s/^"\s*//;
	    $curated =~ s/\s*"$//;

	    if($curated){
		$curatedHash{lc($name)} = $curated;
	    }
	}
	close($curated_dict);
    }

    # 酵素辞書の構築
    open(my $enzyme_dict, $sysroot.'/'.$enzymeDict);
    while(<$enzyme_dict>){
    	chomp;
    	trim( $_ );
    	$enzymeHash{lc($_)} = $_;
    }
    close($enzyme_dict);

=head
    # Locus tagのprefixリストを取得し、辞書を構築
    print "L1.\n";
    my @prefix_array;
    open(my $locustag_prefix, $sysroot.'/'.$locustag_prefix_name);
    while(<$locustag_prefix>){
	chomp;
	s/^"//;
	s/"$//;
	trim( $_ );
	push @prefix_array, lc($_."_");
    }
    close($locustag_prefix);
    $locustag_prefix_matcher = Text::Match::FastAlternatives->new( @prefix_array );

    # EMBLから取得したLocus tagリストの辞書構築
    print "L2.\n";
    my @locustag_array;
    open(my $embl_locustag, $sysroot.'/'.$embl_locustag_name);
    while(<$embl_locustag>){
	chomp;
	my ($eid, $lct) = split /\t/;
	next if $eid eq '"emblid"';
	$lct =~ s/^"//;
	$lct =~ s/"$//;
	trim( $_ );
	push @locustag_array, lc($_);
    }
    close($embl_locustag);
    $embl_locustag_matcher = Text::Match::FastAlternatives->new( @locustag_array );

    # UniProtのReviewed=Trueなエントリについて、それをコードする遺伝子名のprefLabelにあるシンボル
    print "U.\n";
    my @gene_symbol_array;
    open(my $gene_symbol, $sysroot.'/'.$gene_symbol_name);
    while(<$gene_symbol>){
	chomp;
	trim( $_ );
	push @gene_symbol_array, lc($_);
    }
    close($gene_symbol);
    $gene_symbol_matcher = Text::Match::FastAlternatives->new( @gene_symbol_array );

    # Pfamデータベースにあるファミリー名
    print "P.\n";
    my @pfam_family_array;
    open(my $pfam_family, $sysroot.'/'.$family_name);
    while(<$pfam_family>){
	chomp;
	trim( $_ );
	push @pfam_family_array, lc($_);
    }
    close($pfam_family);
    $family_name_matcher = Text::Match::FastAlternatives->new( @pfam_family_array );
=cut

    # 類似度計算用および変換用辞書の構築
    if( $useCurrentDict ){

	# my $json = read_file($dictdir.'/dump.json', { binmode => ':raw' });
	# my $hash_pack_ptr = decode_json $json;

	# %convtable = %{ $hash_pack_ptr->[0] };
	# %wospconvtableE = %{ $hash_pack_ptr->[1] };
	# %wospconvtableD = %{ $hash_pack_ptr->[2] };
	# %correct_definitions = %{ $hash_pack_ptr->[3] };

    }else{

	my $nite_all;
	if($niteAll =~ /\.gz$/){
	    open($nite_all, "<:gzip", $sysroot.'/'.$niteAll);
	}else{
	    open($nite_all, $sysroot.'/'.$niteAll);
	}
	while(<$nite_all>){
	    chomp;
	    my (undef, $sno, $chk, undef, $name, $b4name, undef) = split /\t/;
	    next if $chk eq 'RNA' or $chk eq 'OK';
	    # next if $chk eq 'RNA' or $chk eq 'del' or $chk eq 'OK';

	    $name //= "";   # $chk が "del" のときは $name が空。
	    trim( $name );
	    trim( $b4name );
	    $name =~ s/^"\s*//;
	    $name =~ s/\s*"$//;
	    $b4name =~ s/^"\s*//;
	    $b4name =~ s/\s*"$//;

	    for ( @sp_words ){
		$name =~ s/^$_\s+//i;
	    }

=head
            $name_provenance{$name} = "dictionary";
	    if($curatedHash{lc($name)}){
		$name = $curatedHash{lc($name)};
		$name_provenance{$name} = "curated (after)";
		# print "#Curated (after): ", $_name, "->", $name, "\n";
	    }else{
		for ( @sp_words ){
		    $name =~ s/^$_\s+//i;
		}
	    }
=cut

	    my $lcb4name = lc($b4name);
	    $lcb4name =~ s{$ignore_chars}{ }g;
	    $lcb4name = trim($lcb4name);
	    $lcb4name =~ s/  +/ /g;
	    for ( @sp_words ){
		if(index($lcb4name, $_) == 0){
		    $lcb4name =~ s/^$_\s+//;
		}
	    }

	    if($chk eq 'del'){
		$convtable{$lcb4name}{'__DEL__'}++;
	    }else{
		$convtable{$lcb4name}{$name}++;

		# $niteall_before_db->insert($lcb4name);
		(my $wosplcb4name = $lcb4name) =~ s/ //g;   #### 全ての空白を取り除く
		$niteall_before_db->insert($wosplcb4name);
		$wospconvtableE{$wosplcb4name}{$lcb4name}++;

		my $lcname = lc($name);
		$lcname =~ s{$ignore_chars}{ }g;
		$lcname = trim($lcname);
		$lcname =~ s/  +/ /g;
		next if $correct_definitions{$lcname};
		$correct_definitions{$lcname} = $name;
		for ( split " ", $lcname ){
		    s/\W+$//;
		    $histogram{$_}++;
		}
		#$niteall_after_db->insert($lcname);
		(my $wosplcname = $lcname) =~ s/ //g;   #### 全ての空白を取り除く
		$niteall_after_db->insert($wosplcname);
		$wospconvtableD{$wosplcname}{$lcname}++;
	    }
	}
	close($nite_all);

	$niteall_after_db->close;
	$niteall_before_db->close;

#	push @hash_pack, \%name_provenance;
#	push @hash_pack, \%convtable;
#	push @hash_pack, \%wospconvtableE;
#	push @hash_pack, \%wospconvtableD;
#	push @hash_pack, \%correct_definitions;
#	my $json = encode_json \@hash_pack;
#	write_file($dictdir.'/dump.json', { binmode => ':raw' }, $json);

	my $s_conv  = $dbh->prepare('INSERT INTO `convtable`           (`tkey`,`json`,`dictionary`)   VALUES (?,?,"'.$md5dname.'")');
	my $s_convE = $dbh->prepare('INSERT INTO `wospconvtableE`      (`tkey`,`json`,`dictionary`)   VALUES (?,?,"'.$md5dname.'")');
	my $s_convD = $dbh->prepare('INSERT INTO `wospconvtableD`      (`tkey`,`json`,`dictionary`)   VALUES (?,?,"'.$md5dname.'")');
	my $s_cd    = $dbh->prepare('INSERT INTO `correct_definitions` (`tkey`,`tvalue`,`dictionary`) VALUES (?,?,"'.$md5dname.'")');
        while(my ($k,$v) = each %convtable){
	    $s_conv->execute($k, encode_json($v)) or die "execution failed: $dbh->errstr()";
	}
        while(my ($k,$v) = each %wospconvtableE){
	    $s_convE->execute($k, encode_json($v)) or die "execution failed: $dbh->errstr()";
	}
        while(my ($k,$v) = each %wospconvtableD){
	    $s_convD->execute($k, encode_json($v)) or die "execution failed: $dbh->errstr()";
	}
        while(my ($k,$v) = each %correct_definitions){
	    $s_cd->execute($k, $v) or die "execution failed: $dbh->errstr()";
	}
	$s_conv->finish();
	$s_convE->finish();
	$s_convD->finish();
	$s_cd->finish();
        $dbh->disconnect();
    }

}

sub openDicts {
    $niteall_after_cs_db = simstring::reader->new($nitealldb_after_name);
    $niteall_after_cs_db->swig_measure_set($simstring::cosine);
    $niteall_after_cs_db->swig_threshold_set($cos_threshold);
    $niteall_before_cs_db = simstring::reader->new($nitealldb_before_name);
    $niteall_before_cs_db->swig_measure_set($simstring::cosine);
    $niteall_before_cs_db->swig_threshold_set($cos_threshold);
    $niteall_after_cs_db = simstring::reader->new($nitealldb_after_name);

    $r_conv  = $dbh->prepare(q/SELECT json FROM `convtable` WHERE tkey=? AND dictionary="/.$md5dname.'"');
    $r_convD = $dbh->prepare(q/SELECT json FROM `wospconvtableD` WHERE tkey=? AND dictionary="/.$md5dname.'"');
    $r_convE = $dbh->prepare(q/SELECT json FROM `wospconvtableE` WHERE tkey=? AND dictionary="/.$md5dname.'"');
    $r_cd    = $dbh->prepare(q/SELECT tvalue FROM `correct_definitions` WHERE tkey=? AND dictionary="/.$md5dname.'"');
    $r_locus_tag_prefix = $dbh->prepare("SELECT tagprefix FROM `locus_tag_prefix` WHERE ? LIKE CONCAT (tagprefix, '\_', '%')");
    $r_embl2locus_tag   = $dbh->prepare("SELECT locus_tag FROM `embl2locus_tag` WHERE locus_tag = ?");
    $r_gene_symbol      = $dbh->prepare("SELECT gene_symbol FROM `gene_symbol_name` WHERE gene_symbol = ?");
    $r_family_name      = $dbh->prepare("SELECT family FROM `family_name` WHERE family = ?");
}

sub closeDicts {
    $niteall_after_cs_db->close;
    $niteall_before_cs_db->close;
    $r_conv->finish;
    $r_convD->finish;
    $r_convE->finish;
    $r_cd->finish;
    $r_locus_tag_prefix->finish;
    $r_embl2locus_tag->finish;
    $r_gene_symbol->finish;
    $r_family_name->finish;
}

sub queryConvTableDB {
    $r_conv->execute($_[0]);
    my $conv_rs;
    if($conv_rs = $r_conv->fetchrow_arrayref){
	$conv_rs = decode_json($conv_rs->[0]);
    }
    return $conv_rs;
}

sub queryWOSPD_DB {
    $r_convD->execute($_[0]);
    my $conv_rs;
    if($conv_rs = $r_convD->fetchrow_arrayref){
	$conv_rs = decode_json($conv_rs->[0]);
    }
    return $conv_rs;
}

sub queryCorrectDefDB {
    $r_cd->execute($_[0]);
    my $conv_rs;
    if($conv_rs = $r_cd->fetchrow_arrayref){
	$conv_rs = $conv_rs->[0];
    }
    return $conv_rs;
}

sub retrieve {
    shift;
    ($minfreq, $minword, $ifhit, $cosdist) = undef;
    my $query = my $oq = shift;
    # $query ||= 'hypothetical protein';
    my $lc_query = $query = lc($query);
    $lc_query =~ s/^"\s*//;
    $lc_query =~ s/\s*"\s*$//;

    $query =~ s{$ignore_chars}{ }g;
    $query =~ s/^"\s*//;
    $query =~ s/\s*"\s*$//;
    $query =~ s/\s+\[\w+\]$//;
    $query =~ s/\s*"$//;
    $query =~ s/  +/ /g;
    $query = trim($query);

    my $prfx = '';
    my ($match, $result, $info) = ('') x 3;
    my @results;
    for ( @sp_words ){
        if(index($query, $_) == 0){
            $query =~ s/^$_\s+//;
	    $prfx = $_. ' ';
	    last;
        }
    }

    $r_conv->execute($query);
    $r_cd->execute($query);

    my $conv_rs;
    if($conv_rs = $r_conv->fetchrow_arrayref){
	$conv_rs = decode_json($conv_rs->[0]);
    }
    my $cd_rs = "";
    if($cd_rs = $r_cd->fetchrow_arrayref){
	$cd_rs = $cd_rs->[0];
    }

    if( $curatedHash{$lc_query} ){ # 最初にcurateにマッチするか
        $match ='ex';
        $result = $curatedHash{$lc_query};
	$info = 'in_curated_dictionary (before)';
	$results[0] = $result;
    }elsif( $cd_rs ){ # 続いてafterに完全マッチするか
#    }elsif( $correct_definitions{$query} ){ # 続いてafterに完全マッチするか
	# print "\tex\t", $prfx. $correct_definitions{$query}, "\tin_dictionary: ", $query;
        $match ='ex';
        $result = $prfx. $cd_rs;
        # $result = $prfx. $correct_definitions{$query};
	$info = 'in_dictionary'. ($prfx?" (prefix=${prfx})":"");
	$results[0] = $result;
    }elsif( $conv_rs ){ # そしてbeforeに完全マッチするか
#    }elsif( $convtable{$query} ){ # そしてbeforeに完全マッチするか
	#### print "\tex\t", $prfx. $convtable{$query}, "\tconvert_from: ", $query;
	if( $conv_rs->{'__DEL__'} ){
	# if($convtable{$query}{'__DEL__'}){
	    my @others = grep {$_ ne '__DEL__'} keys %{ $conv_rs };
	    # my @others = grep {$_ ne '__DEL__'} keys %{$convtable{$query}};
	    $match = 'del';
	    $result = $query;
	    $info = 'Human check preferable (other entries with the same "before" entry: '.join(" @@ ", @others).')';
	}else{
	    $match = 'ex';
	    $result = join(" @@ ", map {$prfx. $_} keys %{ $conv_rs });
	    # $result = join(" @@ ", map {$prfx. $_} keys %{$convtable{$query}});
	    $info = 'convert_from dictionary'. ($prfx?" (prefix=${prfx})":"");
	    $results[0] = $result;
	}
    }else{ # そして類似マッチへ
	my $avoidcsFlag = 0;
	for ( @avoid_cs_terms ){
	    $avoidcsFlag = ($query =~ m,\b$_$,);
	    last if $avoidcsFlag;
	}

	#全ての空白を取り除く処理をした場合への対応
	#my $retr = $niteall_after_cs_db->retrieve($query);
	(my $qwosp = $query) =~ s/ //g;
	my $retr = [ "" ];
	if(defined($qwosp)){
	    $retr = $niteall_after_cs_db->retrieve($qwosp);
	}
	#####
	my %qtms = map {$_ => 1} grep {s/\W+$//;$histogram{$_}} (split " ", $query);
	if($retr->[0]){
	    ($minfreq, $minword, $ifhit, $cosdist) = getScore($retr, \%qtms, 1, $qwosp);
	    my %cache;
	    #全ての空白を取り除く処理をした場合には検索結果の文字列を復元する必要があるため、下記部分をコメントアウトしている。
	    #my @out = sort {$minfreq->{$a} <=> $minfreq->{$b} || $a =~ y/ / / <=> $b =~ y/ / /} grep {$cache{$_}++; $cache{$_} == 1} @$retr;
	    #その代わり以下のコードが必要。
	    my @out = sort by_priority grep {$cache{$_}++; $cache{$_} == 1} map { keys %{ queryWOSPD_DB($_) } } @$retr; #### 要対応
	    # my @out = sort by_priority grep {$cache{$_}++; $cache{$_} == 1} map { keys %{$wospconvtableD{$_}} } @$retr; #### 要対応
	    #####
	    my $le = (@out > $cs_max)?($cs_max-1):$#out;
	    # print "\tcs\t", join(" @@ ", (map {$prfx.$correct_definitions{$_}.' ['.$minfreq->{$_}.':'.$minword->{$_}.']'} @out[0..$le]));
	    if($avoidcsFlag && $minfreq->{$out[0]} == -1 && $negative_min_words{$minword->{$out[0]}}){
		$match ='no_hit';
		$result = $oq;
		$info = 'cs_avoidance';
	    }else{
		$match = 'cs';
		$result = $prfx.queryCorrectDefDB($out[0]);
		$info   = join(" @@ ", (map {$prfx.queryCorrectDefDB($out[0]).' ['.$minfreq->{$_}.':'.$minword->{$_}.']'} @out[0..$le]));
		@results = map { $prfx.queryCorrectDefDB($out[0]) } @out[0..$le];

		# $result = $prfx.$correct_definitions{$out[0]};
		# $info   = join(" @@ ", (map {$prfx.$correct_definitions{$_}.' ['.$minfreq->{$_}.':'.$minword->{$_}.']'} @out[0..$le]));
		# @results = map { $prfx.$correct_definitions{$_} } @out[0..$le];
	    }
	}else{
	    #全ての空白を取り除く処理をした場合への対応
	    #my $retr_e = $niteall_before_cs_db->retrieve($query);
	    my $retr_e = [ "" ];
	    if(defined($qwosp)){
		$retr_e = $niteall_before_cs_db->retrieve($qwosp);
	    }
	    #####
	    if($retr_e->[0]){
		($minfreq, $minword, $ifhit, $cosdist) = getScore($retr_e, \%qtms, 0, $qwosp);
		my @hits = keys %$ifhit;
		my %cache;
		my @out = sort by_priority grep {$cache{$_}++; $cache{$_} == 1 && $minfreq->{$_} < $e_threashold} @hits;
		my $le = (@out > $cs_max)?($cs_max-1):$#out;
		# print "\tbcs\t", join(" % ", (map {$prfx.$convtable{$_}.' ['.$minfreq->{$_}.':'.$minword->{$_}.']'} @out[0..$le]));
		if(defined $out[0] && $avoidcsFlag && $minfreq->{$out[0]} == -1 && $negative_min_words{$minword->{$out[0]}}){
		    $match ='no_hit';
		    $result = $oq;
		    $info = 'bcs_avoidance';
		}else{
		    $match = 'bcs';
		    $result = $oq;
		    if(defined($out[0]) && (my $qcr = queryConvTableDB($out[0]))){
			$result = join(" @@ ", map {$prfx. $_} keys %{ $qcr });
		    }
		    # $result = defined $out[0] ? join(" @@ ", map {$prfx. $_} keys %{$convtable{$out[0]}}) : $oq; ##### convtable対応
		    if(defined $out[0]){
			$info   = join(" % ", (map {join(" @@ ", map {$prfx. $_} keys %{ queryConvTableDB($_) }).' ['.$minfreq->{$_}.':'.$minword->{$_}.']'} @out[0..$le]));
			# $info   = join(" % ", (map {join(" @@ ", map {$prfx. $_} keys %{$convtable{$_}}).' ['.$minfreq->{$_}.':'.$minword->{$_}.']'} @out[0..$le])); ##### convtable対応
		    }else{
			$info   = "Cosine_Sim_To:".join(" % ", @$retr_e);
		    } 
		}
	    } else {
		# print "\tno_hit\t";
		$match  = 'no_hit';
		$result = $oq;
	    }
	}
    }
    # print "\n";
    if($enzymeHash{lc($result)}){
	$info .= " [Enzyme name]";
    }
    for (split " ", lc($result)){
	$r_embl2locus_tag->execute($_);
	if($r_embl2locus_tag->fetchrow_arrayref){
	    $info .= " [Locus tag]";
	}elsif(/_/){
	    $r_locus_tag_prefix->execute($_);
	    if($r_locus_tag_prefix->fetchrow_arrayref){
		$info .= " [Locus prefix]";
	    }
	}
	# if($embl_locustag_matcher->exact_match($_)){
	#     $info .= " [Locus tag]";
	# }elsif($locustag_prefix_matcher->match_at($_, 0)){
	#     $info .= " [Locus prefix]";
	# }
    }
    $r_gene_symbol->execute($lc_query);
    if($r_gene_symbol->fetchrow_arrayref){
	$info .= " [Gene symbol]";
    }
    $r_family_name->execute($lc_query);
    if($r_family_name->fetchrow_arrayref){
	$info .= " [Family name]";
    }

    # if($gene_symbol_matcher->exact_match($lc_query)){
    # 	$info .= " [Gene symbol]";
    # }
    # if($family_name_matcher->exact_match($lc_query)){
    # 	$info .= " [Family name]";
    # }
    $result = b2a($result);

    $r_conv->finish;
    $r_cd->finish;

    return({'query'=> $oq, 'result' => $result, 'match' => $match, 'info' => $info, 'result_array' => \@results});
}

sub by_priority {
  #my $minfreq = shift;
  #    my $cosdist = shift;
      
      #  $minfreq->{$a} <=> $minfreq->{$b} || $cosdist->{$b} <=> $cosdist->{$a} || $a =~ y/ / / <=> $b =~ y/ / /
      ## $cosdist->{$b} <=> $cosdist->{$a} || $minfreq->{$a} <=> $minfreq->{$b} || $a =~ y/ / / <=> $b =~ y/ / /
        guideline_penalty($a) <=> guideline_penalty($b)
         or 
        $minfreq->{$a} <=> $minfreq->{$b}
         or 
        $cosdist->{$b} <=> $cosdist->{$a}
         or 
        $a =~ y/ / / <=> $b =~ y/ / /
}

sub guideline_penalty {
 my $result = shift; 
 my $idx = 0;

#1. (酵素名辞書に含まれている場合)
 $idx-- if $enzymeHash{lc($result)};

#2. 記述や句ではなく簡潔な名前を用いる。
 $idx++ if $result =~/ (of|or|and) /;
#5. タンパク質名が不明な場合は、 産物名として、"unknown” または "hypothetical protein”を用いる。今回の再アノテーションでは、"hypothetical protein”の使用を推奨する。
 $idx++ if $result =~/(unknown protein|uncharacterized protein)/;
#7. タンパク質名に分子量の使用は避ける。例えば、"unicornase 52 kDa subunit”は避け、"unicornase subunit A” 等と表記する。
 $idx++ if $result =~/\d+\s*kDa/;
#8. 名前に“homolog”を使わない。
 $idx++ if $result =~/homolog/;
#9. 可能なかぎり、コンマを用いない。
 $idx++ if $result =~/\,/;
#12. 可能な限りローマ数字は避け、アラビア数字を用いる。
 $idx++ if $result =~/[I-X]/;
#16. ギリシャ文字は、小文字でスペルアウトする（例：alpha）。ただし、ステロイドや脂肪酸代謝での「デルタ」は例外として語頭を大文字にする（Delta）。さらに、番号が続いている場合、ダッシュ" -“の後に続ける（例：unicornase alpha-1）。
 $idx++ if $result =~/(\p{Greek})/;
#17. アクセント、ウムラウトなどの発音区別記号を使用しない。多くのコンピュータシステムは、ASCII文字しか判別できない。 
 $idx++ if $result =~/(\p{Mn})/;


#3. 理想的には命名する遺伝子名（タンパク質名）はユニークであり、すべてのオルソログに同じ名前がついているとよい。
#4. タンパク質名に、タンパク質の特定の特徴を入れない。 例えば、タンパク質の機能、細胞内局在、ドメイン構造、分子量やその起源の種名はノートに記述する。
#6. タンパク質名は、対応する遺伝子と同じ表記を用いる。ただし，語頭を大文字にする。
#10. 語頭は基本的に小文字を用いる。（例外：DNA、ATPなど）
#11. スペルはアメリカ表記を用いる。→ 実装済み（b2a関数の適用）
#13. 略記に分子量を組み込まない。
#14. 多重遺伝子ファミリーに属するタンパク質では、ファミリーの各メンバーを指定する番号を使用することを推奨する。
#15. 相同性または共通の機能に基づくファミリーに分類されるタンパク質に名前を付ける場合、"-"に後にアラビア数字を入れて標記する。（例："desmoglein-1", "desmoglein-2"など）
#18. 複数形を使用しない。"ankyrin repeats-containing protein 8" は間違い。
#19 機能未知タンパク質のうち既知のドメインまたはモチーフを含む場合、ドメイン名を付して名前を付けてもよい。例えば "PAS domain-containing protein 5" など。
 return $idx;
}


sub getScore {
    my $retr = shift;
    my $qtms = shift;
    my $minf = shift;
    my $query = shift;

    my (%minfreq, %minword, %ifhit, %cosdistance);
    # 対象タンパク質のスコアは、当該タンパク質を構成する単語それぞれにつき、検索対象辞書中での当該単語の出現頻度のうち最小値を割り当てる
    # 最小値を持つ語は $minword{$_} に代入する
    # また、検索タンパク質名を構成する単語が、検索対象辞書からヒットした各タンパク質名に含まれている場合は $ifhit{$_} にフラグが立つ

    #全ての空白を取り除く処理をした場合への対応
    # my $wospct = ($minf)? \%wospconvtableD : \%wospconvtableE;
    my $rconv = $minf? $r_convD : $r_convE;
    my $conv_rs;

    #####
    for (@$retr){
	my $wosp = $_;               # <--- 全ての空白を取り除く処理をした場合への対応
	$rconv->execute($wosp);
	if($conv_rs = $rconv->fetchrow_arrayref){
	    $conv_rs = decode_json($conv_rs->[0]);
	}
	for (keys %{ $conv_rs }){ # <--- 全ての空白を取り除く処理をした場合への対応
	# for (keys %{$wospct->{$_}}){ # <--- 全ての空白を取り除く処理をした場合への対応
	    $cosdistance{$_} = $cosine_object->similarity($query, $wosp, $n_gram);
	    my $score = 100000;
	    my $word = '';
	    my $hitflg = 0;
	    for (split){
		my $h = $histogram{$_} // 0;
		if($qtms->{$_}){
		    $hitflg++;
		}else{
		    $h += 10000;
		}
		if($score > $h){
		    $score = $h;
		    $word = $_;
		}
	    }
	    $minfreq{$_} = $score;
	    $minword{$_} = $word;
	    $ifhit{$_}++ if $hitflg;
	}                            # <--- 全ての空白を取り除く処理をした場合への対応
    }
    # 検索タンパク質名を構成する単語が、ヒットした各タンパク質名に複数含まれる場合には、その中で検索対象辞書中での出現頻度スコアが最小であるものを採用する
    # そして最小の語のスコアは-1とする。
    my $leastwrd = '';
    my $leastscr = 100000;
    for (keys %ifhit){
	if($minfreq{$_} < $leastscr){
	    $leastwrd = $_;
	    $leastscr = $minfreq{$_};
	}
    }
    if($minf && $leastwrd){
	for (keys %minword){
	    $minfreq{$_} = -1 if $minword{$_} eq $minword{$leastwrd};
	}
    }

    return (\%minfreq, \%minword, \%ifhit, \%cosdistance);
}

1;
__END__

=head1 NAME

Protein Definition Normalizer

=head1 SYNOPSIS

normProt.pl -t0.7

=head1 ABSTRACT

配列相同性に基いて複数のプログラムにより自動的に命名されたタンパク質名の表記を、既に人手で正規化されている表記を利用して正規形に変換する。

=head1 COPYRIGHT AND LICENSE

Copyright by Yasunori Yamamoto / Database Center for Life Science
このプログラムはフリーであり、また、目的を問わず自由に再配布および修正可能です。

=cut
