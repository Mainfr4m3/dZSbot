namespace eval ::dZSbot::Modules::Music::LastFm {}

proc ::dZSbot::Modules::Music::LastFm::EnsureHttp {} {

    if {[catch {package require http} error]} {
        return "Tcl http package is not available: $error"
    }

    if {[catch {::dZSbot::Packages::EnsureHttps} error]} {
        return "Tcl tls package is required for Last.fm HTTPS lookups: $error"
    }

    return ""
}

proc ::dZSbot::Modules::Music::LastFm::Fetch {query {format ""}} {

    set apiKey [::dZSbot::Config::Get lastfm.api_key ""]
    if {$apiKey eq ""} {
        return [dict create ok 0 error "Last.fm API key is missing. Set lastfm.api_key in config/modules/music.conf."]
    }

    set packageError [EnsureHttp]
    if {$packageError ne ""} {
        return [dict create ok 0 error $packageError]
    }

    set endpoint [::dZSbot::Config::Get lastfm.endpoint "https://ws.audioscrobbler.com/2.0/"]
    set limit [::dZSbot::Config::Get lastfm.limit 1]
    set timeout [::dZSbot::Config::Get lastfm.timeout_ms 15000]
    set userAgent [::dZSbot::Config::Get lastfm.user_agent "dZSbot/2.0 +https://github.com/Mainfr4m3/dZSbot"]
    set params [list method album.search album $query api_key $apiKey format json limit $limit]
    set url "${endpoint}?[::http::formatQuery {*}$params]"

    if {[catch {
        set httpToken [::http::geturl $url -timeout $timeout -headers [list User-Agent $userAgent Accept application/json]]
        set status [::http::status $httpToken]
        set code [::http::ncode $httpToken]
        set data [::http::data $httpToken]
        ::http::cleanup $httpToken
    } error]} {
        return [dict create ok 0 error $error]
    }

    if {$status ne "ok" || $code < 200 || $code >= 300} {
        return [dict create ok 0 error "HTTP status $status ($code)"]
    }

    return [dict create ok 1 data $data]
}
