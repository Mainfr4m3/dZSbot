namespace eval ::dZSbot::Modules::Music::MusicBrainz {

    variable LastRequestAt 0
}

proc ::dZSbot::Modules::Music::MusicBrainz::EnsureHttp {} {

    if {[catch {package require http} error]} {
        return "Tcl http package is not available: $error"
    }

    if {[catch {::dZSbot::Packages::EnsureHttps} error]} {
        return "Tcl tls package is required for MusicBrainz HTTPS lookups: $error"
    }

    return ""
}

proc ::dZSbot::Modules::Music::MusicBrainz::Fetch {query {format ""}} {

    set packageError [EnsureHttp]
    if {$packageError ne ""} {
        return [dict create ok 0 error $packageError]
    }

    RateLimit

    set endpoint [::dZSbot::Config::Get musicbrainz.endpoint "https://musicbrainz.org/ws/2/release/"]
    set limit [::dZSbot::Config::Get musicbrainz.limit 1]
    set timeout [::dZSbot::Config::Get musicbrainz.timeout_ms 15000]
    set userAgent [::dZSbot::Config::Get musicbrainz.user_agent "dZSbot/2.0 ( https://github.com/Mainfr4m3/dZSbot )"]
    set params [list query $query fmt json limit $limit]
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

proc ::dZSbot::Modules::Music::MusicBrainz::RateLimit {} {

    variable LastRequestAt

    set minInterval [::dZSbot::Config::Get musicbrainz.min_interval_ms 1100]
    set now [clock milliseconds]
    set wait [expr {$minInterval - ($now - $LastRequestAt)}]

    if {$wait > 0} {
        after $wait
    }

    set LastRequestAt [clock milliseconds]
}
