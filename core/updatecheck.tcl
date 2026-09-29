namespace eval ::dZSbot::UpdateCheck {

    variable Scheduled 0
}

proc ::dZSbot::UpdateCheck::CachePath {} {

    return [::dZSbot::Config::Get update_check.cache_file \
        [file join $::dZSbot::Root runtime update-check.tsv]]
}

proc ::dZSbot::UpdateCheck::LoadCache {} {

    set path [CachePath]
    if {![file exists $path]} {
        return {}
    }

    if {[catch {
        set handle [open $path r]
        set line [string trim [read $handle]]
        close $handle
    } error]} {
        ::dZSbot::Logger::Warn "Update check cache read failed: $error"
        return {}
    }

    set fields [split $line "\t"]
    set checkedAt [lindex $fields 0]
    if {![string is integer -strict $checkedAt] || $checkedAt <= 0} {
        return {}
    }

    return [dict create \
        checked_at $checkedAt \
        latest [lindex $fields 1] \
        url [lindex $fields 2]]
}

proc ::dZSbot::UpdateCheck::SaveCache {checkedAt latest url} {

    set path [CachePath]
    set latest [string map [list "\t" " " "\r" " " "\n" " "] $latest]
    set url [string map [list "\t" " " "\r" " " "\n" " "] $url]

    if {[catch {
        file mkdir [file dirname $path]
        set handle [open $path w]
        puts $handle [join [list $checkedAt $latest $url] "\t"]
        close $handle
    } error]} {
        ::dZSbot::Logger::Warn "Update check cache write failed: $error"
        return 0
    }

    return 1
}

proc ::dZSbot::UpdateCheck::EnsureHttp {} {

    if {[catch {package require http} error]} {
        return "Tcl http package is not available: $error"
    }
    if {[catch {package require json} error]} {
        return "Tcl json package is not available: $error"
    }
    if {[catch {::dZSbot::Packages::EnsureHttps} error]} {
        return "Tcl tls package is required for update checks: $error"
    }

    return ""
}

proc ::dZSbot::UpdateCheck::Fetch {} {

    set packageError [EnsureHttp]
    if {$packageError ne ""} {
        return [dict create ok 0 error $packageError]
    }

    set endpoint [::dZSbot::Config::Get update_check.endpoint \
        "https://api.github.com/repos/Mainfr4m3/dZSbot/releases/latest"]
    set timeout [::dZSbot::Config::Get update_check.timeout_ms 10000]
    set userAgent "dZSbot/$::dZSbot::Version"
    set token ""

    if {[catch {
        set token [::http::geturl $endpoint -timeout $timeout -headers [list \
            User-Agent $userAgent \
            Accept application/vnd.github+json \
            X-GitHub-Api-Version 2022-11-28]]
        set status [::http::status $token]
        set code [::http::ncode $token]
        set data [::http::data $token]
    } error]} {
        if {$token ne ""} {
            catch {::http::cleanup $token}
        }
        return [dict create ok 0 error $error]
    }
    ::http::cleanup $token

    if {$status ne "ok" || $code < 200 || $code >= 300} {
        return [dict create ok 0 error "HTTP status $status ($code)"]
    }

    if {[catch {set response [::json::json2dict $data]} error]} {
        return [dict create ok 0 error "response parse failed"]
    }

    set latest [DictGet $response tag_name ""]
    if {$latest eq ""} {
        return [dict create ok 0 error "GitHub response has no tag_name"]
    }

    return [dict create ok 1 \
        latest [NormalizeVersion $latest] \
        url [DictGet $response html_url ""]]
}

proc ::dZSbot::UpdateCheck::NormalizeVersion {value} {

    set value [string trimleft [string trim $value] vV]
    if {[regexp {([0-9]+(?:\.[0-9]+)*)} $value -> version]} {
        return $version
    }

    return "0"
}

proc ::dZSbot::UpdateCheck::CompareVersions {left right} {

    set leftParts [split [NormalizeVersion $left] .]
    set rightParts [split [NormalizeVersion $right] .]
    set count [expr {max([llength $leftParts], [llength $rightParts])}]

    for {set index 0} {$index < $count} {incr index} {
        set leftPart [lindex $leftParts $index]
        set rightPart [lindex $rightParts $index]
        if {$leftPart eq ""} {
            set leftPart 0
        }
        if {$rightPart eq ""} {
            set rightPart 0
        }
        if {$leftPart > $rightPart} {
            return 1
        }
        if {$leftPart < $rightPart} {
            return -1
        }
    }

    return 0
}

proc ::dZSbot::UpdateCheck::Start {} {

    variable Scheduled

    if {![::dZSbot::Config::Get update_check.enabled 1]} {
        ::dZSbot::Health::Set update-check disabled "disabled by configuration"
        return 0
    }
    if {![llength [info commands ::utimer]]} {
        ::dZSbot::Health::Set update-check disabled "utimer unavailable"
        return 0
    }
    if {$Scheduled} {
        return 1
    }

    set Scheduled 1
    set interval [IntervalSeconds]
    set delay 5
    set cache [LoadCache]
    if {$cache ne ""} {
        set delay [expr {[dict get $cache checked_at] + $interval - [clock seconds]}]
        if {$delay < 5} {
            set delay 5
        }
    }

    ::utimer $delay ::dZSbot::UpdateCheck::Run
    ::dZSbot::Health::Set update-check ok "scheduled"
    return $delay
}

proc ::dZSbot::UpdateCheck::Run {} {

    set result [Fetch]
    set now [clock seconds]

    if {![dict get $result ok]} {
        ::dZSbot::Logger::Warn "Update check failed: [dict get $result error]"
        ::dZSbot::Health::Set update-check warn [dict get $result error]
    } else {
        set latest [dict get $result latest]
        set url [dict get $result url]
        SaveCache $now $latest $url
        ::dZSbot::Health::Set update-check ok "latest $latest"

        if {[CompareVersions $latest $::dZSbot::Version] > 0} {
            set channel [::dZSbot::Config::Get update_check.channel ""]
            if {$channel eq ""} {
                set channel [::dZSbot::Config::Get status.admin_channel "#staff"]
            }
            set message "dZSbot update available: v$latest (installed v$::dZSbot::Version)"
            if {$url ne ""} {
                append message " | $url"
            }
            ::dZSbot::Commands::Reply "" $channel $message
        }
    }

    ScheduleNext
    return $result
}

proc ::dZSbot::UpdateCheck::ScheduleNext {} {

    if {[llength [info commands ::utimer]]} {
        ::utimer [IntervalSeconds] ::dZSbot::UpdateCheck::Run
        return 1
    }

    return 0
}

proc ::dZSbot::UpdateCheck::IntervalSeconds {} {

    set interval [::dZSbot::Config::Get update_check.interval_seconds 86400]
    if {![string is integer -strict $interval] || $interval < 60} {
        return 86400
    }

    return $interval
}

proc ::dZSbot::UpdateCheck::DictGet {dictValue key default} {

    if {[catch {dict exists $dictValue $key} exists] || !$exists} {
        return $default
    }

    return [dict get $dictValue $key]
}
