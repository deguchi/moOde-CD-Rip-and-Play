#!/bin/bash
#
# Add ReplayGain tags to FLAC albums, so playback volume is consistent between
# discs without touching the audio itself.
#
# WHY THIS IS FLAC ONLY
#
# MPD has two unrelated ways to even out volume:
#
#   volume_normalization   A dynamic compressor applied to everything that
#                          reaches the output as PCM. It cannot be limited to
#                          one format, so enabling it would process DSD too -
#                          which means converting DSD to PCM and losing the
#                          bit-perfect path. Leave it "no".
#
#   replaygain             Tag driven and per file. A file with no ReplayGain
#                          tags plays completely unmodified.
#
# So "normalise FLAC but not DSD" needs no format switch anywhere: tag the FLAC
# files and leave the DSF/M4A files alone. That is exactly what this script
# does - it refuses to look at anything that is not FLAC.
#
# MPD must have 'replaygain' set to something other than "off" for the tags to
# be used ("auto" uses album gain for album playback and track gain otherwise).
#
# Usage:
#   ./fix-replaygain.sh --scan
#   sudo ./fix-replaygain.sh --all
#   sudo ./fix-replaygain.sh "/mnt/OSDISK/Fujiko Hemming/La Campanella"
#
# Options:
#   --scan          List FLAC albums with no ReplayGain tags and exit
#   --all           Tag every FLAC album that has none
#   --force         Recalculate albums that already carry tags
#   --no-refresh    Do not update the moOde library afterwards
#   --dry-run       Show what would happen, change nothing
#

set -u

##################################################################
# Settings
##################################################################

_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# Follow the project config so the library root tracks the installation.
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

readonly	RG_TAG="REPLAYGAIN_TRACK_GAIN"

OPT_SCAN=0
OPT_ALL=0
OPT_FORCE=0
OPT_NOREFRESH=0
OPT_DRYRUN=0
ALBUM_DIR=""
TOUCHED=0
SKIPPED=0

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

# Album folders holding FLAC. Hidden directories are pruned: '.tmp' holds the
# half-encoded tracks of a rip that is still running.
list_album_dirs() {
	find "${MUSIC_DIR}" -type d -name '.*' -prune -o \
		-type f -iname '*.flac' -printf '%h\n' 2> /dev/null | sort -u
}

# True when every FLAC in the folder already carries a track gain. Requiring
# all of them catches albums that were only partly tagged, e.g. a multi-disc
# rip that was interrupted.
album_has_replaygain() {
	local dir="$1" file
	while IFS= read -r -d '' file; do
		metaflac --show-tag="${RG_TAG}" "${file}" 2> /dev/null | grep -q . || return 1
	done < <(find "${dir}" -maxdepth 1 -type f -iname '*.flac' -print0)
	return 0
}

##################################################################
# Tag one album
##################################################################

process_album() {
	local dir="$1" rates count files=() file

	while IFS= read -r -d '' file; do
		files+=( "${file}" )
	done < <(find "${dir}" -maxdepth 1 -type f -iname '*.flac' -print0 | sort -z)

	count="${#files[@]}"
	if [ "${count}" -eq 0 ]; then
		return 0
	fi

	echo ""
	echo "=== ${dir}"
	echo "    FLAC files: ${count}"

	# 'metaflac --add-replay-gain' refuses a set of files with differing
	# sample rates, and the album gain is only meaningful across one album, so
	# check before touching anything.
	# '--no-filename' matters: given more than one file metaflac prefixes every
	# line with the path, so without it each line is unique and every album
	# looks like it has mixed rates.
	rates=$(metaflac --no-filename --show-sample-rate "${files[@]}" 2> /dev/null | sort -u | tr '\n' ' ')
	if [ "$(wc -w <<< "${rates}")" -gt 1 ]; then
		echo "    SKIPPED: mixed sample rates (${rates% }) - split the discs into separate folders" >&2
		SKIPPED=$((SKIPPED + 1))
		return 0
	fi
	echo "    Sample rate: ${rates% } Hz"

	if [ "${OPT_DRYRUN}" -eq 1 ]; then
		echo "    [dry-run] would add track and album ReplayGain tags"
		return 0
	fi

	# Ripped files are 444. Make them writable for the rewrite, then put the
	# read-only mode back exactly as it was.
	for file in "${files[@]}"; do
		chmod u+w "${file}" || die "cannot write ${file} - run this script with sudo"
	done

	# All tracks in ONE invocation: that is what makes ALBUM_GAIN correct.
	# --preserve-modtime keeps moOde from treating every track as changed.
	if metaflac --preserve-modtime --add-replay-gain "${files[@]}"; then
		echo "    Added ReplayGain tags to ${count} file(s)."
		TOUCHED=$((TOUCHED + 1))
	else
		echo "    ERROR: metaflac failed for this album" >&2
		SKIPPED=$((SKIPPED + 1))
	fi

	for file in "${files[@]}"; do
		chmod 444 "${file}"
	done

	# Show what the album ended up with - a sanity check that is worth having
	# when a whole library is processed in one run.
	metaflac --show-tag=REPLAYGAIN_ALBUM_GAIN "${files[0]}" 2> /dev/null | sed 's/^/    /'
}

##################################################################
# Refresh
#
# MPD caches decoded tag data, so ask moOde to reindex. This must go through
# 'dashboard.php': it is the only entry point that resolves the real session id
# before submitting the job, so a job submitted from curl actually runs.
##################################################################

update_library() {
	echo ""
	echo "Updating the moOde library..."
	curl -s -o /dev/null "http://localhost/command/music-library.php?cmd=clear_libcache_all" || true
	curl -s -o /dev/null "http://localhost/command/dashboard.php?cmd=update_library" || true
}

##################################################################
# Arguments
##################################################################

while [ $# -gt 0 ]; do
	case "$1" in
		--scan)		OPT_SCAN=1 ;;
		--all)		OPT_ALL=1 ;;
		--force)	OPT_FORCE=1 ;;
		--no-refresh)	OPT_NOREFRESH=1 ;;
		--dry-run)	OPT_DRYRUN=1 ;;
		-h|--help)	usage ;;
		-*)		die "unknown option: $1" ;;
		*)
			[ -n "${ALBUM_DIR}" ] && die "too many arguments"
			ALBUM_DIR="${1%/}"
			;;
	esac
	shift
done

command -v metaflac > /dev/null 2>&1 || die "'metaflac' is not installed"

##################################################################
# Main
##################################################################

if [ "${OPT_SCAN}" -eq 1 ]; then
	[ -d "${MUSIC_DIR}" ] || die "music directory not found: ${MUSIC_DIR}"
	echo "FLAC albums without ReplayGain tags under ${MUSIC_DIR}:"
	found=0
	while IFS= read -r dir; do
		album_has_replaygain "${dir}" && continue
		found=$((found + 1))
		printf '  %s\n' "${dir}"
	done < <(list_album_dirs)
	[ "${found}" -eq 0 ] && echo "  (none - every FLAC album is tagged)"
	echo ""
	echo "DSD and lossy files are never considered - leaving them untagged is"
	echo "what keeps them out of ReplayGain entirely."
	exit 0
fi

if [ "${OPT_ALL}" -eq 1 ]; then
	[ -d "${MUSIC_DIR}" ] || die "music directory not found: ${MUSIC_DIR}"
	[ -n "${ALBUM_DIR}" ] && die "--all takes no album folder"
	while IFS= read -r dir; do
		if [ "${OPT_FORCE}" -eq 0 ] && album_has_replaygain "${dir}"; then
			continue
		fi
		process_album "${dir}"
	done < <(list_album_dirs)
elif [ -n "${ALBUM_DIR}" ]; then
	[ -d "${ALBUM_DIR}" ] || die "album folder not found: ${ALBUM_DIR}"
	[ -n "$(find "${ALBUM_DIR}" -maxdepth 1 -type f -iname '*.flac' -print -quit)" ] \
		|| die "no FLAC files in: ${ALBUM_DIR}"
	if [ "${OPT_FORCE}" -eq 0 ] && album_has_replaygain "${ALBUM_DIR}"; then
		echo "${ALBUM_DIR} already has ReplayGain tags - use --force to recalculate."
		exit 0
	fi
	process_album "${ALBUM_DIR}"
else
	usage
fi

if [ "${TOUCHED}" -gt 0 ] && [ "${OPT_DRYRUN}" -eq 0 ]; then
	[ "${OPT_NOREFRESH}" -eq 0 ] && update_library
	echo ""
	echo "=== Done - ${TOUCHED} album(s) tagged, ${SKIPPED} skipped ==="
else
	echo ""
	echo "=== Done - no album was changed (${SKIPPED} skipped) ==="
fi
