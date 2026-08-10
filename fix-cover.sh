#!/bin/bash
#
# Assign album artwork to albums that were ripped without a cover.
#
# 'abcde' only reaches two artwork sources during a rip: Cover Art Archive
# (looked up with the MusicBrainz release id, so it silently does nothing when
# the disc was identified through CDDB/gnudb only) and 'glyrc'. Japanese
# releases and compilations regularly miss both, and the album then shows the
# moOde placeholder cover forever.
#
# This script re-runs the artwork search after the fact, against MORE sources
# than the rip does, and writes the result the same way a successful rip would:
# a 'cover.jpg' in the album folder plus an embedded FRONT_COVER picture block
# in every FLAC.
#
# NOTE ON CDDB: gnudb/CDDB itself carries no artwork - it only returns track
# metadata - so adding another CDDB server cannot fix a missing cover. What
# helps is adding artwork sources, which is what SOURCES below does.
#
# Sources, tried in order:
#   caa      Cover Art Archive, found via a MusicBrainz release search
#   itunes   Apple iTunes Search API (much the best coverage for Japanese discs)
#   discogs  Discogs, only when a token is available - the one source that
#            reliably has Japanese-only pressings and label compilations.
#            Discogs answers unauthenticated searches, but blanks out every
#            image url, so a token is not optional for artwork.
#
#            Get one at https://www.discogs.com/settings/developers ->
#            "Generate new token" (personal access token; no app registration
#            and no OAuth needed for read-only use). Then either:
#              echo "<token>" > <install_dir>/.discogs-token
#            or export DISCOGS_TOKEN=... before running. The file is read
#            because 'sudo' drops the environment.
#   glyrc    whatever 'glyrc' finds (Last.fm, Jamendo, MusicBrainz)
#
# Usage:
#   sudo ./fix-cover.sh --scan
#   sudo ./fix-cover.sh "/mnt/OSDISK/Various Artists/image 4"
#   sudo ./fix-cover.sh "/mnt/OSDISK/Various Artists/image 4" https://example/art.jpg
#   sudo ./fix-cover.sh "/mnt/OSDISK/Various Artists/image 4" /home/deguchi/art.jpg
#   sudo ./fix-cover.sh --all
#
# Options:
#   --scan          List albums that have no artwork and exit
#   --all           Walk every album that has no artwork
#   --auto          Take the best candidate instead of prompting
#   --query "..."   Override the search terms for a single album
#   --no-embed      Only write 'cover.jpg', leave the FLAC tags alone
#   --no-refresh    Do not rebuild the moOde library afterwards
#   --force         Also process albums that already have artwork
#   --dry-run       Show what would happen, change nothing
#
# Rip-time use:
#   fix-cover.sh --fetch <out.jpg> --album "..." [--artist "..."]
#
# Searches the sources and writes the artwork to <out.jpg>, touching nothing
# else. Never prompts, and exits non-zero when nothing confidently matches, so
# the rip can fall back to the placeholder cover. 'abcde.conf' calls this from
# post_encode() when 'abcde' itself came back empty handed.
#

set -u

##################################################################
# Settings
##################################################################

_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# Pick up MUSIC_HOME_PATH / RIPPED_MUSIC_DIR from the project config so the
# library root follows the installation rather than being hard coded here.
MUSIC_DIR="/mnt/OSDISK"
if [ -f "${_DIRECTORY}/cd-rip-and-or-play.conf" ]; then
	_CONF_HOME=$(grep -E '^\s*readonly\s+MUSIC_HOME_PATH=' "${_DIRECTORY}/cd-rip-and-or-play.conf" | head -1 | sed -E 's/.*="([^"]*)".*/\1/')
	_CONF_DIR=$(grep -E '^\s*readonly\s+RIPPED_MUSIC_DIR=' "${_DIRECTORY}/cd-rip-and-or-play.conf" | head -1 | sed -E 's/.*="([^"]*)".*/\1/')
	_CONF_SUB=$(grep -E '^\s*readonly\s+MUSIC_SUB_DIR=' "${_DIRECTORY}/cd-rip-and-or-play.conf" | head -1 | sed -E 's/.*="([^"]*)".*/\1/')
	if [ -n "${_CONF_HOME:-}" ] && [ -n "${_CONF_DIR:-}" ]; then
		MUSIC_DIR="${_CONF_HOME}/${_CONF_DIR}"
		[ -n "${_CONF_SUB:-}" ] && MUSIC_DIR="${MUSIC_DIR}/${_CONF_SUB}"
	fi
fi
MUSIC_DIR="${MUSIC_DIR_OVERRIDE:-${MUSIC_DIR}}"

readonly	ALBUMARTFILE="cover.jpg"
readonly	CONVERTOPTS="-resize 600x600>"		# Same geometry the rip uses
readonly	ITUNES_COUNTRY="JP"
readonly	USER_AGENT="caliljp-fix-cover/1.0 ( https://github.com/ )"
readonly	MIN_COVER_BYTES=2048			# Anything smaller is a placeholder

# 'sudo' wipes DISCOGS_TOKEN out of the environment, so fall back to a token
# file - next to the script, or in the home of whoever called sudo.
DISCOGS_TOKEN="${DISCOGS_TOKEN:-}"
if [ -z "${DISCOGS_TOKEN}" ]; then
	for _tokenfile in "${_DIRECTORY}/.discogs-token" \
		"$(getent passwd "${SUDO_USER:-${USER:-root}}" 2> /dev/null | cut -d: -f6)/.discogs-token"; do
		if [ -n "${_tokenfile}" ] && [ -r "${_tokenfile}" ]; then
			DISCOGS_TOKEN=$(tr -d '[:space:]' < "${_tokenfile}")
			break
		fi
	done
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

OPT_SCAN=0
OPT_ALL=0
OPT_AUTO=0
OPT_NOEMBED=0
OPT_NOREFRESH=0
OPT_FORCE=0
OPT_DRYRUN=0
OPT_QUERY=""
OPT_FETCH=""
OPT_ALBUM=""
OPT_ARTIST=""
ALBUM_DIR=""
IMAGE_SRC=""
TOUCHED=0

##################################################################
# Helpers
##################################################################

usage() {
	sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit 1
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

urlencode() {
	python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$1"
}

# Read one Vorbis comment from the first FLAC of an album folder.
album_tag() {
	local dir="$1" tag="$2" file
	file=$(find "${dir}" -maxdepth 1 -name '*.flac' -print -quit)
	[ -z "${file}" ] && return 0
	metaflac --show-tag="${tag}" "${file}" 2>/dev/null | head -1 | cut -d= -f2-
}

# An album counts as having artwork if a cover file sits next to the tracks -
# moOde prefers that - or, failing that, if EVERY track carries an embedded
# picture. Requiring all of them catches albums where a rip embedded the cover
# into only some tracks, which shows up as a half-covered album in moOde.
album_has_art() {
	local dir="$1" file
	for name in Cover.jpg cover.jpg Cover.jpeg cover.jpeg Cover.png cover.png \
		Folder.jpg folder.jpg Folder.jpeg folder.jpeg Folder.png folder.png; do
		[ -f "${dir}/${name}" ] && return 0
	done
	[ -n "$(find "${dir}" -maxdepth 1 -name '*.flac' -print -quit)" ] || return 1
	while IFS= read -r -d '' file; do
		metaflac --list --block-type=PICTURE "${file}" 2> /dev/null | grep -q 'PICTURE' || return 1
	done < <(find "${dir}" -maxdepth 1 -name '*.flac' -print0)
	return 0
}

list_album_dirs() {
	# Prune hidden directories: '.tmp' holds the half-encoded tracks of a rip
	# that is still running and '.Music CDs Ripped' the disc-id playlists.
	# Neither is an album, and writing into a live rip would corrupt it.
	find "${MUSIC_DIR}" -type d -name '.*' -prune -o \
		-type f -name '*.flac' -printf '%h\n' 2> /dev/null | sort -u
}

##################################################################
# Artwork sources
#
# Each source appends "<source>|<title>|<artist>|<year>|<url>" lines to
# ${WORKDIR}/candidates. 'glyrc' has no browsable url, so it downloads
# straight to a file and reports that path instead.
##################################################################

search_caa() {
	local album="$1" artist="$2" query mbids id

	query="release:\"${album}\""
	[ -n "${artist}" ] && [ "${artist}" != "Various Artists" ] && query="${query} AND artist:\"${artist}\""

	mbids=$(curl -s -m 20 -A "${USER_AGENT}" \
		"https://musicbrainz.org/ws/2/release/?query=$(urlencode "${query}")&fmt=json&limit=5" \
		| python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d.get("releases", []):
    ac = r.get("artist-credit") or [{}]
    print("\t".join([
        r.get("id", ""),
        (r.get("title") or "").replace("\t", " "),
        (ac[0].get("name") or "").replace("\t", " "),
        (r.get("date") or "")[:4],
    ]))
')

	[ -z "${mbids}" ] && return 0

	while IFS=$'\t' read -r id title rartist year; do
		[ -z "${id}" ] && continue
		# Cover Art Archive 307-redirects to the image when art exists.
		if curl -s -m 15 -o /dev/null -I -L -w '%{http_code}' \
			"https://coverartarchive.org/release/${id}/front" | grep -q '^200$'; then
			printf 'caa|%s|%s|%s|%s\n' "${title}" "${rartist}" "${year}" \
				"https://coverartarchive.org/release/${id}/front" >> "${WORKDIR}/candidates"
		fi
		sleep 1	# MusicBrainz/CAA ask for max one request per second
	done <<< "${mbids}"
}

search_itunes() {
	local album="$1" artist="$2" term

	term="${album}"
	[ -n "${artist}" ] && [ "${artist}" != "Various Artists" ] && term="${artist} ${album}"

	curl -s -m 20 -A "${USER_AGENT}" \
		"https://itunes.apple.com/search?country=${ITUNES_COUNTRY}&media=music&entity=album&limit=5&term=$(urlencode "${term}")" \
		| python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d.get("results", []):
    url = r.get("artworkUrl100") or ""
    if not url:
        continue
    # The search API only hands back a 100px thumbnail; the same path serves
    # the full size artwork when the geometry segment is swapped out.
    url = url.replace("100x100bb", "1200x1200bb")
    print("|".join([
        "itunes",
        (r.get("collectionName") or "").replace("|", "/"),
        (r.get("artistName") or "").replace("|", "/"),
        (r.get("releaseDate") or "")[:4],
        url,
    ]))
' >> "${WORKDIR}/candidates"
}

search_discogs() {
	local album="$1" artist="$2" term

	[ -z "${DISCOGS_TOKEN:-}" ] && return 0

	term="${album}"
	[ -n "${artist}" ] && [ "${artist}" != "Various Artists" ] && term="${artist} ${album}"

	curl -s -m 20 -A "${USER_AGENT}" \
		"https://api.discogs.com/database/search?type=release&per_page=5&q=$(urlencode "${term}")&token=$(urlencode "${DISCOGS_TOKEN}")" \
		| python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# A rejected token still returns valid json, just without any results, so say
# so rather than looking like Discogs simply had nothing.
if d.get("message"):
    print("  Discogs: " + d["message"], file=sys.stderr)
for r in d.get("results", []):
    url = r.get("cover_image") or ""
    # Discogs hands back its own "no image" spacer for release without art.
    if not url or "spacer.gif" in url:
        continue
    title = (r.get("title") or "").replace("|", "/")
    artist, _, name = title.partition(" - ")
    print("|".join([
        "discog",
        (name or title).strip(),
        artist.strip(),
        str(r.get("year") or ""),
        url,
    ]))
' >> "${WORKDIR}/candidates"
}

search_glyrc() {
	local album="$1" artist="$2" out="${WORKDIR}/glyrc.img"

	command -v glyrc > /dev/null 2>&1 || return 0
	[ -z "${artist}" ] && artist="${album}"

	env LC_ALL=C glyrc cover --artist "${artist}" --album "${album}" \
		--write "${out}" --from "all" > /dev/null 2>&1

	if [ -s "${out}" ] && [ "$(wc -c < "${out}")" -ge "${MIN_COVER_BYTES}" ]; then
		printf 'glyrc|%s|%s||file://%s\n' "${album}" "${artist}" "${out}" >> "${WORKDIR}/candidates"
	fi
}

# Obscure discs - Japanese label compilations especially - are in none of the
# databases above. Print ready-made search links so the artwork can be found by
# hand and fed back in with the <url-or-file> argument.
print_manual_hints() {
	local album="$1" artist="$2" dir="$3" term enc

	term="${album}"
	[ -n "${artist}" ] && [ "${artist}" != "Various Artists" ] && term="${artist} ${album}"
	enc=$(urlencode "${term}")

	echo "  Look for the jacket by hand:"
	echo "    https://www.google.com/search?tbm=isch&q=${enc}"
	echo "    https://www.amazon.co.jp/s?i=popular&k=${enc}"
	echo "    https://www.discogs.com/search/?type=release&q=${enc}"
	echo "  Then assign it with:"
	echo "    sudo $0 \"${dir}\" <url-or-file>"
}

# Reduce a title to something comparable: lower case, no punctuation, no
# spaces. Used only to sanity check automatic picks.
normalise_title() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^[:alnum:]]+//g'
}

# Query every source in turn, filling ${WORKDIR}/candidates.
search_all() {
	local album="$1" artist="$2"

	rm -f "${WORKDIR}/candidates"
	touch "${WORKDIR}/candidates"

	search_caa "${album}" "${artist}"
	search_itunes "${album}" "${artist}"
	search_discogs "${album}" "${artist}"
	search_glyrc "${album}" "${artist}"

	[ -s "${WORKDIR}/candidates" ]
}

# Decide whether a candidate really is the album we are looking at.
#
# Nothing picked without a human in the loop may be trusted on rank alone: the
# top hit for a disc the databases do not carry is confidently wrong, and a
# wrong cover gets burned into every track. "image 4", for instance, matches a
# CADEJO single called "Image #4".
candidate_matches() {
	local album="$1" artist="$2" line="$3" want got wanta gota

	want=$(normalise_title "${album}")
	got=$(normalise_title "$(cut -d'|' -f2 <<< "${line}")")
	wanta=$(normalise_title "${artist}")
	gota=$(normalise_title "$(cut -d'|' -f3 <<< "${line}")")

	[ -n "${want}" ] || return 1

	# Titles must contain one another - "The Köln Concert (Live)" is still the
	# Köln Concert, "Image #4" is still image 4.
	if [ "${got#*"${want}"}" = "${got}" ] && [ "${want#*"${got}"}" = "${want}" ]; then
		return 1
	fi

	# A compilation must not take the artwork of some artist's own record that
	# happens to share the title. Single-artist albums get no such check: the
	# iTunes JP catalogue returns artist names in Japanese ("キース・ジャレット"
	# for Keith Jarrett), so comparing them would throw away correct matches.
	if [ "${wanta}" = "variousartists" ] && [ "${gota}" != "variousartists" ]; then
		return 1
	fi

	return 0
}

##################################################################
# Fetch a candidate into a local file and normalise it to jpeg
##################################################################

fetch_image() {
	local src="$1" dst="$2" tmp="${WORKDIR}/download.bin"

	rm -f "${tmp}"
	case "${src}" in
		file://*)	cp -f "${src#file://}" "${tmp}" || return 1 ;;
		http://*|https://*)
			curl -s -m 60 -L -A "${USER_AGENT}" -o "${tmp}" "${src}" || return 1 ;;
		*)		cp -f "${src}" "${tmp}" || return 1 ;;
	esac

	[ -s "${tmp}" ] || return 1
	[ "$(wc -c < "${tmp}")" -ge "${MIN_COVER_BYTES}" ] || return 1
	identify "${tmp}" > /dev/null 2>&1 || return 1

	# -flatten drops any alpha channel onto white, which keeps transparent PNG
	# artwork from turning into a black square once it is saved as jpeg.
	convert "${tmp}" -background white -flatten ${CONVERTOPTS} -quality 90 "${dst}" 2>/dev/null || return 1
	[ -s "${dst}" ] || return 1
	return 0
}

##################################################################
# Install artwork into an album folder
##################################################################

install_cover() {
	local dir="$1" newcover="$2" owner target count=0

	target="${dir}/${ALBUMARTFILE}"

	# Ripped files belong to the account that ran the rip and are chmod 444;
	# match that so the new artwork is indistinguishable from a normal rip.
	owner=$(find "${dir}" -maxdepth 1 -name '*.flac' -printf '%u:%g\n' -quit)
	owner="${owner:-root:root}"

	if [ "${OPT_DRYRUN}" -eq 1 ]; then
		echo "  [dry-run] would write ${target} (owner ${owner})"
		[ "${OPT_NOEMBED}" -eq 0 ] && echo "  [dry-run] would embed the picture into every FLAC"
		return 0
	fi

	install -m 444 -o "${owner%%:*}" -g "${owner##*:}" "${newcover}" "${target}" \
		|| die "could not write ${target} - run this script with sudo"
	echo "  Wrote: ${target} ($(identify -format '%wx%h' "${target}" 2> /dev/null))"

	if [ "${OPT_NOEMBED}" -eq 1 ]; then
		return 0
	fi

	while IFS= read -r -d '' file; do
		echo "  Embedding: $(basename "${file}")"
		chmod u+w "${file}"
		# Drop any stale picture block first, otherwise metaflac appends a
		# second FRONT_COVER and players pick whichever they see first.
		metaflac --remove --block-type=PICTURE "${file}" 2> /dev/null
		metaflac --import-picture-from="3||||${target}" "${file}" \
			|| echo "  WARNING: could not embed into $(basename "${file}")" >&2
		chmod 444 "${file}"
		count=$((count + 1))
	done < <(find "${dir}" -maxdepth 1 -name '*.flac' -print0 | sort -z)

	echo "  Embedded into ${count} file(s)."
}

##################################################################
# Process one album folder
##################################################################

process_album() {
	local dir="$1" album artist choice pick src line i

	album=$(album_tag "${dir}" ALBUM)
	artist=$(album_tag "${dir}" ALBUMARTIST)
	[ -z "${artist}" ] && artist=$(album_tag "${dir}" ARTIST)
	[ -z "${album}" ] && album=$(basename "${dir}")

	echo ""
	echo "=== ${dir}"
	echo "    Album:  ${album}"
	echo "    Artist: ${artist:-(unknown)}"

	# An explicit image was handed to us - no searching needed.
	if [ -n "${IMAGE_SRC}" ]; then
		if fetch_image "${IMAGE_SRC}" "${WORKDIR}/cover.jpg"; then
			install_cover "${dir}" "${WORKDIR}/cover.jpg"
			TOUCHED=$((TOUCHED + 1))
		else
			echo "  ERROR: could not read image: ${IMAGE_SRC}" >&2
		fi
		return 0
	fi

	local sterm="${album}" sartist="${artist}"
	if [ -n "${OPT_QUERY}" ]; then
		sterm="${OPT_QUERY}"
		sartist=""
	fi

	if ! search_all "${sterm}" "${sartist}"; then
		echo "  No artwork found."
		print_manual_hints "${album}" "${artist}" "${dir}"
		return 0
	fi

	i=0
	while IFS='|' read -r src title rartist year url; do
		i=$((i + 1))
		printf '  %2d) [%-6s] %s / %s %s\n' "${i}" "${src}" "${title}" "${rartist:-?}" "${year:+(${year})}"
		printf '      %s\n' "${url}"
	done < "${WORKDIR}/candidates"

	if [ "${OPT_AUTO}" -eq 1 ]; then
		if ! candidate_matches "${album}" "${artist}" "$(head -1 "${WORKDIR}/candidates")"; then
			echo "  No candidate confidently matches this album - skipping."
			print_manual_hints "${album}" "${artist}" "${dir}"
			return 0
		fi
		choice=1
	else
		echo ""
		# Read from the terminal, not stdin, so this still prompts while the
		# album list is being piped in from find.
		read -r -p "  Pick 1-${i}, (u)rl, (s)kip [1]: " choice < /dev/tty
		choice="${choice:-1}"
	fi

	case "${choice}" in
		s|S|"")		echo "  Skipped."; return 0 ;;
		u|U)
			read -r -p "  URL or file path: " pick < /dev/tty
			[ -z "${pick}" ] && { echo "  Skipped."; return 0; }
			;;
		''|*[!0-9]*)	echo "  Skipped."; return 0 ;;
		*)
			[ "${choice}" -ge 1 ] && [ "${choice}" -le "${i}" ] || { echo "  Skipped."; return 0; }
			pick=$(sed -n "${choice}p" "${WORKDIR}/candidates" | cut -d'|' -f5-)
			;;
	esac

	if fetch_image "${pick}" "${WORKDIR}/cover.jpg"; then
		install_cover "${dir}" "${WORKDIR}/cover.jpg"
		TOUCHED=$((TOUCHED + 1))
	else
		echo "  ERROR: could not download or convert: ${pick}" >&2
	fi
}

##################################################################
# Refresh moOde so the new artwork is picked up
#
# The library cache stores a cover hash per album, so a plain 'mpc update' is
# not enough - the cache has to be dropped for moOde to re-read the folder.
##################################################################

update_library() {
	echo ""
	echo "Updating MPD and moOde library..."
	mpc update > /dev/null 2>&1 || true
	sleep 2
	curl -s -o /dev/null "http://localhost/command/music-library.php?cmd=clear_libcache_all" || true
	curl -s -o /dev/null "http://localhost/command/music-library.php?cmd=update_library" || true
}

##################################################################
# Arguments
##################################################################

while [ $# -gt 0 ]; do
	case "$1" in
		--scan)		OPT_SCAN=1 ;;
		--all)		OPT_ALL=1 ;;
		--auto)		OPT_AUTO=1 ;;
		--no-embed)	OPT_NOEMBED=1 ;;
		--no-refresh)	OPT_NOREFRESH=1 ;;
		--force)	OPT_FORCE=1 ;;
		--dry-run)	OPT_DRYRUN=1 ;;
		--query)	shift; OPT_QUERY="${1:-}" ;;
		--fetch)	shift; OPT_FETCH="${1:-}" ;;
		--album)	shift; OPT_ALBUM="${1:-}" ;;
		--artist)	shift; OPT_ARTIST="${1:-}" ;;
		-h|--help)	usage ;;
		-*)		die "unknown option: $1" ;;
		*)
			if [ -z "${ALBUM_DIR}" ]; then
				ALBUM_DIR="${1%/}"
			elif [ -z "${IMAGE_SRC}" ]; then
				IMAGE_SRC="$1"
			else
				die "too many arguments"
			fi
			;;
	esac
	shift
done

for tool in metaflac convert curl python3; do
	command -v "${tool}" > /dev/null 2>&1 || die "'${tool}' is not installed"
done

##################################################################
# Main
##################################################################

# Rip-time mode. Deliberately independent of the music library: the rip calls
# this while the album is still in the temporary encode directory.
if [ -n "${OPT_FETCH}" ]; then
	[ -n "${OPT_ALBUM}" ] || die "--fetch needs --album"

	if ! search_all "${OPT_ALBUM}" "${OPT_ARTIST}"; then
		echo "fix-cover: no artwork found for '${OPT_ALBUM}'"
		exit 1
	fi

	_TOP=$(head -1 "${WORKDIR}/candidates")
	if ! candidate_matches "${OPT_ALBUM}" "${OPT_ARTIST}" "${_TOP}"; then
		echo "fix-cover: no confident match for '${OPT_ALBUM}' (best was '$(cut -d'|' -f2 <<< "${_TOP}")')"
		exit 1
	fi

	if ! fetch_image "$(cut -d'|' -f5- <<< "${_TOP}")" "${OPT_FETCH}"; then
		echo "fix-cover: could not download the artwork for '${OPT_ALBUM}'"
		exit 1
	fi

	echo "fix-cover: artwork for '${OPT_ALBUM}' from $(cut -d'|' -f1 <<< "${_TOP}") -> ${OPT_FETCH}"
	exit 0
fi

[ -d "${MUSIC_DIR}" ] || die "music directory not found: ${MUSIC_DIR}"

if [ "${OPT_SCAN}" -eq 1 ]; then
	echo "Albums without artwork under ${MUSIC_DIR}:"
	found=0
	while IFS= read -r dir; do
		album_has_art "${dir}" && continue
		found=$((found + 1))
		printf '  %s\n' "${dir}"
	done < <(list_album_dirs)
	[ "${found}" -eq 0 ] && echo "  (none - every album has a cover)"
	exit 0
fi

if [ "${OPT_ALL}" -eq 1 ]; then
	[ -n "${ALBUM_DIR}" ] && die "--all takes no album folder"
	while IFS= read -r dir; do
		if [ "${OPT_FORCE}" -eq 0 ] && album_has_art "${dir}"; then
			continue
		fi
		process_album "${dir}"
	done < <(list_album_dirs)
elif [ -n "${ALBUM_DIR}" ]; then
	[ -d "${ALBUM_DIR}" ] || die "album folder not found: ${ALBUM_DIR}"
	[ -n "$(find "${ALBUM_DIR}" -maxdepth 1 -name '*.flac' -print -quit)" ] \
		|| die "no FLAC files in: ${ALBUM_DIR}"
	if [ "${OPT_FORCE}" -eq 0 ] && [ -z "${IMAGE_SRC}" ] && album_has_art "${ALBUM_DIR}"; then
		echo "${ALBUM_DIR} already has artwork - use --force to replace it."
		exit 0
	fi
	process_album "${ALBUM_DIR}"
else
	usage
fi

if [ "${TOUCHED}" -gt 0 ] && [ "${OPT_DRYRUN}" -eq 0 ]; then
	[ "${OPT_NOREFRESH}" -eq 0 ] && update_library
	echo ""
	echo "=== Done - artwork assigned to ${TOUCHED} album(s) ==="
else
	echo ""
	echo "=== Done - no album was changed ==="
fi
