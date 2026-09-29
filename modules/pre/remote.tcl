namespace eval ::dZSbot::Modules::Pre::Remote {}

proc ::dZSbot::Modules::Pre::Remote::EnsureHttp {} {

    if {[catch {package require http} error]} {
        return "Tcl http package is not available: $error"
    }
    if {[catch {package require json} error]} {
        return "Tcl json package is not available: $error"
    }
    if {[catch {::dZSbot::Packages::EnsureHttps} error]} {
        return "Tcl tls package is required for PreDB HTTPS lookups: $error"
    }

    return ""
}

proc ::dZSbot::Modules::Pre::Remote::Fetch {query {type ""}} {

    set packageError [EnsureHttp]
    if {$packageError ne ""} {
        return [dict create ok 0 error $packageError]
    }

    set endpoint [::dZSbot::Config::Get pre.remote.endpoint "https://api.predb.net/"]
    set timeout [::dZSbot::Config::Get pre.remote.timeout_ms 10000]
    set userAgent [::dZSbot::Config::Get pre.remote.user_agent "dZSbot/2.0 ( https://github.com/Mainfr4m3/dZSbot )"]
    set params {}

    if {[string trim $query] ne ""} {
        lappend params q [string trim $query]
    }
    if {[string trim $type] ne ""} {
        lappend params type [string tolower [string trim $type]]
    }

    set url $endpoint
    if {[llength $params]} {
        append url ? [::http::formatQuery {*}$params]
    }

    set httpToken ""
    if {[catch {
        set httpToken [::http::geturl $url -timeout $timeout \
            -headers [list User-Agent $userAgent Accept application/json]]
        set status [::http::status $httpToken]
        set code [::http::ncode $httpToken]
        set data [::http::data $httpToken]
    } error]} {
        if {$httpToken ne ""} {
            catch {::http::cleanup $httpToken}
        }
        return [dict create ok 0 error $error]
    }
    ::http::cleanup $httpToken

    if {$status ne "ok" || $code < 200 || $code >= 300} {
        return [dict create ok 0 error "HTTP status $status ($code)"]
    }

    return [dict create ok 1 data $data]
}

proc ::dZSbot::Modules::Pre::Remote::Search {query {limit 5} {type ""}} {

    if {![::dZSbot::Config::Get pre.remote.enabled 0]} {
        return [dict create ok 0 disabled 1 error "remote PreDB is disabled" rows {}]
    }
    if {[catch {package require json} error]} {
        return [dict create ok 0 error "Tcl json package is not available: $error" rows {}]
    }

    set fetched [Fetch $query $type]
    if {![dict get $fetched ok]} {
        ::dZSbot::Health::Set pre:remote warn [dict get $fetched error]
        return [dict create ok 0 error [dict get $fetched error] rows {}]
    }

    if {[catch {
        set response [::json::json2dict [dict get $fetched data]]
    } error]} {
        ::dZSbot::Health::Set pre:remote warn "invalid JSON response"
        return [dict create ok 0 error "response parse failed" rows {}]
    }

    if {[DictGet $response status ""] ne "success"} {
        set message [DictGet $response message "API returned an error"]
        ::dZSbot::Health::Set pre:remote warn $message
        return [dict create ok 0 error $message rows {}]
    }

    set data [DictGet $response data {}]
    if {[catch {dict exists $data rows} hasRows] == 0 && $hasRows} {
        set data [dict get $data rows]
    }

    set rows {}
    foreach item $data {
        set row [Normalize $item]
        if {[dict get $row relname] eq ""} {
            continue
        }
        lappend rows $row
        if {[llength $rows] >= $limit} {
            break
        }
    }

    ::dZSbot::Health::Set pre:remote ok "api.predb.net"
    return [dict create ok 1 rows $rows]
}

proc ::dZSbot::Modules::Pre::Remote::Normalize {item} {

    set status [DictGet $item status 0]
    set reason [DictGet $item reason [DictGet $item nuke ""]]
    set nukeReason ""
    if {$reason ne "" && $status ni {0 ""}} {
        set nukeReason $reason
    }

    return [dict create \
        id [DictGet $item id ""] \
        section [string toupper [DictGet $item section [DictGet $item cat "UNKNOWN"]]] \
        relname [DictGet $item release [DictGet $item name ""]] \
        u_name "PreDB.net" \
        g_name [DictGet $item group [DictGet $item team "UNKNOWN"]] \
        nukereason $nukeReason \
        pretime [DictGet $item pretime 0] \
        predate "" \
        preage 0 \
        size [SizeToKilobytes [DictGet $item size ""]] \
        files [DictGet $item files 0]]
}

proc ::dZSbot::Modules::Pre::Remote::SizeToKilobytes {value} {

    # PreDB.net reports release sizes in MB; dZSbot PRE storage uses KB.
    if {$value eq "" || ![string is double -strict $value]} {
        return $value
    }

    return [expr {$value * 1024.0}]
}

proc ::dZSbot::Modules::Pre::Remote::DictGet {dictValue key default} {

    if {[catch {dict exists $dictValue $key} exists] || !$exists} {
        return $default
    }

    return [dict get $dictValue $key]
}
