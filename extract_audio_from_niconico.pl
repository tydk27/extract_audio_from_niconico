#!/usr/bin/perl

use 5.010;
use strict;
use warnings;

use File::Basename qw(basename);
use YAML::Syck;
use XML::Simple;
use CGI;
use LWP::UserAgent;
use HTTP::Cookies;
use HTTP::Request;
use HTTP::Request::Common;
use HTTP::Headers;
use Furl;

if (@ARGV != 1) { die "USAGE: perl get_niconico.pl [file]\n"; }

my $file = shift;
open(my $fh, "<", $file) or die "Cannot open $file: $!";

# 設定読込
my $my_name = basename($0, '.pl');
my $conf = YAML::Syck::LoadFile("$my_name.yaml");

# ログイン処理
my $ua = LWP::UserAgent->new(keep_alive => 1);
$ua->cookie_jar( {} );
my $cookies = login($conf->{auth}, $conf->{api}->{auth});
$ua->cookie_jar($cookies);

say "login as $conf->{auth}->{mail}";

while (my $id = readline $fh) {
    chomp $id;

    # 動画情報取得
    my $info = XMLin($ua->get("$conf->{api}->{thumbinfo}$id")->content)->{thumb};
    my $type = $info->{movie_type};
    say "${id}'s type: $type";

    # 拡張子識別
    my $ext;
    given($type) {
        when(/mp4/) { $ext = 'mp4'; }
        when(/flv/) { $ext = 'mp3'; }
        when(/swf/) { $ext = 'mp3'; }
        default { say "This video's extension is not mp4, flv or swf. skip"; next; }
    }

    # 403エラー回避
    $ua->get("$conf->{api}->{watch}$id");

    # 動画URL取得
    my $res;
    my $swf = "";
    # swf(nm******)の場合はパラメータを付与
    if ($type =~ /swf/) { $swf = "?as3=1"; }
    $res = $ua->get("$conf->{api}->{getflv}$id$swf");

    my $q = CGI->new($res->content);
    my $url = $q->param('url') or die "Failed: $res->content\n";

    # エコノミーはスキップ
    if ($url =~ /low$/) {
        say "This video is low-quality mode... skip";
        next;
    }
    say "$url => $id.$type";

    # ファイルダウンロード
    $res = $ua->request(HTTP::Request->new( GET => $url ), "tmp/$id.$type");

    # ffmpegで音声抽出
    defined(my $pid = fork) or die "Cannot fork: $!";
    unless ($pid) {
        my $audio_id = 1;
        # flv形式の場合、audioIDが0になる（要検証）
        if ($ext eq "mp3") { $audio_id = 0; }
        exec "ffmpeg -i tmp/$id.$type -acodec copy -map 0:$audio_id audio/$id.audio.$ext" or die "Cannnot exec ffmpeg: $!";
    }
    waitpid($pid, 0);
    unlink "tmp/$id.$type";
}

close $fh;
say "finished!!";

sub login {
    my ($config) = $_[0];
    my $auth_url = $_[1];

    my $f = Furl->new(max_redirects => 0);
    my $req = POST $auth_url, $config;
    my $res = $f->request($req)->as_http_response;
    $res->request($req);
    my $cookies = HTTP::Cookies->new();
    $cookies->extract_cookies($res);

    return $cookies;
}
