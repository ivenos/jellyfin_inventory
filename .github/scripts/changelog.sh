#!/bin/sh
# Keeps CHANGELOG.md: a dependency line for Renovate, the stamp of a release, and its release notes.
set -eu

FILE="${CHANGELOG:-CHANGELOG.md}"

die() {
    echo "changelog: $*" >&2
    exit 1
}

rewrite() {
    awk "$@" "$FILE" > "$FILE.tmp" || {
        status=$?
        rm -f "$FILE.tmp"
        return "$status"
    }
    mv "$FILE.tmp" "$FILE"
}

dependency() {
    [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || die "a dependency needs a name, the old and the new version"
    export NAME="$1" FROM="$2" TO="$3"
    rewrite '
        { line[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (line[i] ~ /^## \[Unreleased\]/) start = i
                else if (start && !stop && line[i] ~ /^(## \[|\[[^]]+\]: )/) stop = i
            }
            if (!start) exit 2
            if (!stop) stop = NR + 1
            last = stop - 1
            while (last > start && line[last] == "") last--
            for (i = start + 1; i <= last; i++) {
                if (line[i] == "### Dependencies") deps = i
                else if (deps && !after && line[i] ~ /^### /) after = i
            }
            name = ENVIRON["NAME"]
            entry = "- " name " " ENVIRON["FROM"] " -> " ENVIRON["TO"]
            if (!deps) {
                at = last
                entry = "\n### Dependencies\n\n" entry
            } else {
                at = deps
                for (i = deps + 1; i < (after ? after : last + 1); i++) {
                    split(line[i], part, " ")
                    if (part[1] == "-" && part[2] == name && part[4] == "->") {
                        pulls = match(line[i], / \(#[0-9, #]+\)$/) ? substr(line[i], RSTART) : ""
                        line[i] = "- " name " " part[3] " -> " ENVIRON["TO"] pulls
                        at = 0
                        break
                    }
                    if (line[i] ~ /^- /) at = i
                }
                if (at == deps) entry = "\n" entry
            }
            for (i = 1; i <= NR; i++) {
                print line[i]
                if (i == at) print entry
            }
        }' || die "$FILE has no Unreleased section"
}

merged() {
    dir=$(dirname "$FILE")
    git -C "$dir" rev-parse --git-dir > /dev/null 2>&1 || return 0
    [ "$(git -C "$dir" rev-parse --is-shallow-repository)" = false ] || die "the pull request numbers need the full history, this clone is shallow"
    range=HEAD
    last=$(sed -n 's|^\[Unreleased\]: .*/compare/\(.*\)\.\.\.HEAD$|\1|p' "$FILE")
    if [ -n "$last" ]; then
        git -C "$dir" rev-parse -q --verify "refs/tags/$last" > /dev/null || die "the tag $last of the last release is missing"
        range="$last..HEAD"
    fi
    git -C "$dir" log --format='commit %s' -U0 "$range" -- "$(basename "$FILE")" | awk '
        /^commit / { pull = match($0, / \(#[0-9]+\)$/) ? substr($0, RSTART + 3, RLENGTH - 4) : "" }
        pull && /^\+- / && $4 == "->" { print $2, pull }'
}

release() {
    version=$1
    day=${2:-$(date -u +%F)}
    echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "$version is not a version such as 1.2.3"
    if grep -qF "## [$version]" "$FILE"; then die "$version is in $FILE already"; fi
    MERGED=$(merged)
    export VERSION="$version" DAY="$day" MERGED
    rewrite '
        function numbered(text,    part, all, found, count, i, j, swap, list) {
            split(text, part, " ")
            all = merged[part[2]]
            if (match(text, / \(#[0-9, #]+\)$/)) {
                all = all " " substr(text, RSTART + 2, RLENGTH - 3)
                text = substr(text, 1, RSTART - 1)
            }
            gsub(/[#,]/, "", all)
            count = split(all, found, " ")
            for (i = 1; i <= count; i++) {
                for (j = i + 1; j <= count; j++) {
                    if (found[j] + 0 < found[i] + 0) { swap = found[i]; found[i] = found[j]; found[j] = swap }
                }
            }
            for (i = 1; i <= count; i++) {
                if (i == 1 || found[i] != found[i - 1]) list = list (list ? ", " : "") "#" found[i]
            }
            return text (list ? " (" list ")" : "")
        }
        { line[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (line[i] ~ /^## \[Unreleased\]/) start = i
                else if (start && !stop && line[i] ~ /^(## \[|\[[^]]+\]: )/) stop = i
                if (line[i] ~ /^\[Unreleased\]: /) link = i
            }
            if (!start) exit 2
            if (!stop) stop = NR + 1
            for (i = start + 1; i < stop; i++) if (line[i] ~ /^- /) entries++
            if (!entries) exit 3
            rows = split(ENVIRON["MERGED"], row, "\n")
            for (i = 1; i <= rows; i++) {
                if (split(row[i], pair, " ") == 2) merged[pair[1]] = merged[pair[1]] " " pair[2]
            }
            for (i = start + 1; i < stop; i++) {
                if (line[i] ~ /^### /) deps = (line[i] == "### Dependencies")
                else if (deps && line[i] ~ /^- [^ ]+ [^ ]+ -> /) line[i] = numbered(line[i])
            }
            version = ENVIRON["VERSION"]
            for (i = 1; i <= NR; i++) {
                if (i == start) {
                    print "## [Unreleased]\n\n## [" version "] - " ENVIRON["DAY"]
                } else if (i == link) {
                    url = substr(line[i], length("[Unreleased]: ") + 1)
                    at = index(url, "/compare/")
                    if (at) {
                        base = substr(url, 1, at - 1)
                        previous = substr(url, at + length("/compare/"))
                        sub(/\.\.\.HEAD$/, "", previous)
                        print "[Unreleased]: " base "/compare/v" version "...HEAD"
                        print "[" version "]: " base "/compare/" previous "...v" version
                    } else {
                        base = url
                        sub(/\/commits\/.*$/, "", base)
                        print "[Unreleased]: " base "/compare/v" version "...HEAD"
                        print "[" version "]: " base "/releases/tag/v" version
                    }
                } else {
                    print line[i]
                }
            }
        }' || case $? in
        3) die "nothing is listed under Unreleased in $FILE" ;;
        *) die "$FILE has no Unreleased section" ;;
    esac
}

notes() {
    export VERSION="$1"
    awk '
        BEGIN {
            version = ENVIRON["VERSION"]
            emoji["Breaking changes"] = "🚨"
            emoji["Added"] = "✨"
            emoji["Changed"] = "🔄"
            emoji["Deprecated"] = "⚠️"
            emoji["Removed"] = "🗑️"
            emoji["Fixed"] = "🐛"
            emoji["Security"] = "🔒"
            emoji["Dependencies"] = "📦"
        }
        index($0, "[" version "]: ") == 1 { url = substr($0, length(version) + 5) }
        inside && /^(## \[|\[[^]]+\]: )/ { inside = 0 }
        inside { body[++count] = $0 }
        index($0, "## [" version "]") == 1 { inside = found = 1 }
        END {
            if (!found) exit 2
            while (count && body[count] == "") count--
            first = 1
            while (first <= count && body[first] == "") first++
            if (first > count) exit 3
            for (i = first; i <= count; i++) {
                text = body[i]
                if (text ~ /^### /) {
                    name = substr(text, 5)
                    deps = (name == "Dependencies")
                    text = "## " (name in emoji ? emoji[name] " " : "") name
                } else if (deps) {
                    gsub(/ -> /, " → ", text)
                }
                print text
            }
            at = index(url, "/compare/")
            if (at) print "\n**Full changelog:** [" substr(url, at + length("/compare/")) "](" url ")"
        }' "$FILE" || case $? in
        3) die "nothing is listed under $1 in $FILE" ;;
        *) die "$FILE has no section for $1" ;;
    esac
}

case "${1:-}" in
    dependency)
        if [ -n "${RENOVATE_POST_UPGRADE_COMMAND_DATA_FILE:-}" ]; then
            while IFS='	' read -r name from to || [ -n "$name" ]; do
                if [ -n "$from" ] && [ -n "$to" ]; then dependency "$name" "$from" "$to"; fi
            done < "$RENOVATE_POST_UPGRADE_COMMAND_DATA_FILE"
        else
            [ $# -eq 4 ] || die "usage: changelog.sh dependency NAME FROM TO"
            dependency "$2" "$3" "$4"
        fi
        ;;
    release)
        [ $# -ge 2 ] || die "usage: changelog.sh release VERSION [DATE]"
        release "$2" "${3:-}"
        ;;
    notes)
        [ $# -eq 2 ] || die "usage: changelog.sh notes VERSION"
        notes "$2"
        ;;
    *)
        die "usage: changelog.sh dependency NAME FROM TO | release VERSION [DATE] | notes VERSION"
        ;;
esac
