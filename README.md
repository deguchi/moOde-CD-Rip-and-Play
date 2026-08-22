# moOde-CD-Rip-and-Play

> **This is a fork of [TheMetalHead/moOde-CD-Rip-and-Play](https://github.com/TheMetalHead/moOde-CD-Rip-and-Play), updated for moOde 10.2.0 compatibility.**

A companion program for the moOde audio player (http://moodeaudio.org/) to rip and tag CDs and play them. Either as 320kbps mp3 files, flac and/or mpc.

This is not a program for an alternative user interface to moOde.

It allows a user to play their CDs without using the moOde interface. The volume being adjusted using an attached rotary encoder. CDs that have already been ripped can be batch queued for playing. It sort of emulates the old fashioned juke box except that instead of feeding in money, you feed in the discs.

Is copying CDs legal? If you are not sure what the position is for the country you live in, please check your local copyright law to make sure that you are on the right side of the law before using the software featured here.

## Requirements

- moOde audio player v10.x (tested on v10.2.0)
- Raspberry Pi 3 / 4 / 5
- Raspberry Pi OS Trixie (Debian 13)
- An external USB CD drive

### Tested on

| Component        | Version            |
| ---------------- | ------------------ |
| moOde            | 10.2.0             |
| Raspberry Pi OS  | Trixie (Debian 13) |
| Raspberry Pi     | 3                  |

Raspberry Pi 4 and 5 should also work but have not been tested.

## Installation

```shell
git clone https://github.com/deguchi/moOde-CD-Rip-and-Play.git
cd moOde-CD-Rip-and-Play
chmod 544 *.sh
sudo ./Install-cd-rip.sh
```

The installer checks for and installs the required programs, generates the systemd service files from templates, and creates the required links for moOde.

Required programs (installed automatically):

- abcde, cd-discid, cdparanoia
- lame, flac, mpcenc
- glyrc, eyeD3, imagemagick, ffmpeg
- eject, flock, touch, truncate, mpc, mpd

## Uninstalling

```shell
sudo ./Remove-cd-rip.sh
```

The ripped music will be left untouched, but the hidden disc id directory `.Music CDs Ripped` will be removed.

## Updating

```shell
cd ~/moOde-CD-Rip-and-Play
git pull
chmod 544 *.sh
sudo ./Install-cd-rip.sh
```

Your `cd-rip-and-or-play.conf` settings will be preserved. The systemd service files are regenerated from templates on each install, so `git pull` will not overwrite your configured paths.

## Usage

Insert the CD into the drive. The CD will be checked to see if it has been previously ripped. If not, the ripping process will take about 12 minutes. After this, the CD will be ejected and moOde will play the ripped files. If the CD has been previously ripped, it will be ejected and moOde will play the ripped files. More CDs can be inserted for batch queueing.

Cover art is fetched automatically and embedded in each track. See [Album artwork](#album-artwork) if a disc ends up with the placeholder cover.

## Configuration

Edit the configuration file as required: `cd-rip-and-or-play.conf`

By default, ripped files are stored under `/mnt/OSDISK/` so they appear in the moOde library alongside your other music. The following variables can be adjusted:

| Variable | Default | Description |
| --- | --- | --- |
| `MUSIC_HOME_PATH` | `/mnt` | Full path to the music files. Do not add any trailing slashes. |
| `RIPPED_MUSIC_DIR` | `OSDISK` | Directory containing the music files. Do not add any leading/trailing slashes. |
| `RIPPED_MUSIC_OWNER` | auto-detected | File ownership. WARNING: The owner existence is not checked. |
| `LIBRARY_TAG` | `OSDISK` | The name displayed in the moOde library menu. |
| `MUSIC_MNT_SOURCE` | `OSDISK` | Mount name under `/mnt`. Can be OSDISK, CD, NAS, USB, NVME or SATA. |
| `MUSIC_SUB_DIR` | (empty) | Optional subdirectory to separate ripped music from other files. |
| `DEFAULT_VOLUME` | `10` | The default volume that moOde will play the CD at. |

The encoding configuration is in `abcde.conf`. Each track is placed in a subdirectory named after the artist/album. File format can be changed via `OUTPUTFORMAT` and `VAOUTPUTFORMAT`.

## Album artwork

### During a rip

`abcde` looks for a cover in two places: CoverArtArchive (reached with a MusicBrainz release id) and `glyrc`. A disc identified through CDDB/gnudb alone never produces a MusicBrainz id, so that first source is skipped — which is why Japanese pressings and compilations often finish with the placeholder cover.

When `abcde` comes back empty handed, `fix-cover.sh` is called from `post_encode()` in `abcde.conf` and repeats the search against more sources:

| Source | Notes |
| --- | --- |
| CoverArtArchive | Found via a MusicBrainz release search by name, not by disc id |
| iTunes Search API | No key required. By far the best coverage for Japanese discs |
| Discogs | Requires a token (see below). The only reliable source for Japan-only pressings and label compilations |
| glyrc | Last.fm, Jamendo, MusicBrainz |

The result is written exactly like a normal rip: a `cover.jpg` in the album folder plus an embedded `FRONT_COVER` picture in every track.

A candidate is only accepted when its title matches the disc, and a compilation will not take the artwork of some artist's own record that happens to share a title. A search that finds nothing convincing leaves the album without a cover rather than embedding the wrong one, and the placeholder is used as before.

### Discogs token

Discogs answers unauthenticated searches but blanks out every image URL, so a token is required for artwork.

1. Sign in to Discogs and open <https://www.discogs.com/settings/developers>
2. Press **Generate new token** under *Personal access token*
3. Save it next to the scripts:

```shell
umask 077
echo "<your token>" > ~/moOde-CD-Rip-and-Play/.discogs-token
```

Read-only use needs nothing more — no app registration and no OAuth. The token is read from `DISCOGS_TOKEN`, then `<install_dir>/.discogs-token`, then `~/.discogs-token`. The file is used because `sudo` drops the environment. `.discogs-token` is in `.gitignore`. Without a token Discogs is simply skipped.

### Fixing albums that were already ripped

`fix-cover.sh` also assigns artwork after the fact. Writing into the library needs `sudo`; scanning does not.

```shell
# List albums with no artwork
./fix-cover.sh --scan

# Search every one of them and pick from the candidates
sudo ./fix-cover.sh --all

# Assign a specific image to one album (URL or local file)
sudo ./fix-cover.sh "/mnt/OSDISK/Various Artists/image 4" https://example.com/jacket.jpg
```

Candidates are listed with their source, title, artist, year and URL. Open the URL to check the image, then enter its number — or `u` to type a different URL, or `s` to skip. When no source has the disc, search links for Google Images, Amazon and Discogs are printed so the jacket can be found by hand and passed back in.

Imported albums are handled too, not only ripped ones. Any folder containing `flac`, `dsf`, `dff`, `m4a`, `mp3`, `wav` or `aiff` is considered; tags are read with `metaflac` for FLAC and `ffprobe` for everything else. **Only FLAC gets an embedded picture** — DSD and lossy files are left byte-for-byte untouched and rely on the folder `cover.jpg`, which is all moOde needs to display a cover.

An album counts as having artwork when the folder contains *any* image file (moOde's `parseDir()` prefers `cover.*`/`folder.*` but falls back to globbing any `jpg`/`png`/`tif`), or when *every* track carries an embedded picture — so albums where only some tracks got the cover are picked up too.

### If a new cover does not appear in the WebUI

moOde names each cached thumbnail after `md5()` of the album's folder path and, in `thumb-gen.php`, only generates one when that file is **missing**:

```php
if (!file_exists(THMCACHE_DIR . md5($dirA) . '.jpg'))
```

So an album cached with the placeholder keeps showing the placeholder no matter how good the new cover is — `update_library` will not replace it. `fix-cover.sh` deletes the two affected cache entries whenever it assigns artwork, so this resolves itself. To rebuild every thumbnail by hand, use *Configure → Library → Regenerate thumbnail cache*, or:

```shell
curl -s "http://localhost/command/dashboard.php?cmd=regen_thmcache"
```

| Option | Description |
| --- | --- |
| `--scan` | List albums with no artwork and exit |
| `--all` | Walk every album with no artwork |
| `--auto` | Take the best candidate instead of prompting. Skips anything that does not confidently match |
| `--query "..."` | Override the search terms for one album |
| `--no-embed` | Only write `cover.jpg`, leave the FLAC tags alone |
| `--no-refresh` | Do not rebuild the moOde library afterwards |
| `--force` | Also process albums that already have artwork |
| `--dry-run` | Show what would happen, change nothing |

Ripped tracks are chmod 444, so the script makes each file writable, embeds the picture and restores the read-only mode. The new `cover.jpg` is given the same mode and owner as the tracks it sits with. Afterwards the moOde library cache is cleared and rebuilt, which is what makes the new artwork show up in the WebUI.

## Volume normalization (FLAC only)

Ripped CDs and DSD/SACD transfers sit at very different levels, so playback volume jumps between albums. MPD offers two unrelated ways to even this out, and only one of them can be limited to a single format:

| Setting | Applies to | Can be limited per format? |
| --- | --- | --- |
| `volume_normalization` | A dynamic compressor on everything reaching the output as PCM | **No.** It would process DSD too, which means converting DSD to PCM and losing the bit-perfect path. Leave it `no`. |
| `replaygain` | Tag driven, per file. A file with no ReplayGain tags plays completely unmodified | **Yes, implicitly** — tag the files you want normalized |

So "normalize FLAC but leave DSD alone" needs no format switch anywhere. Tag the FLAC files, leave the DSF/M4A files untagged, and DSD stays bit-perfect. `fix-replaygain.sh` refuses to look at anything that is not FLAC, precisely so this stays true.

Set moOde's *Configure → Audio → ReplayGain* to something other than `off`. `auto` uses album gain for album playback and track gain otherwise.

### During a rip

`abcde.conf` calls `fix-replaygain.sh` from `post_encode()` once the album has been renamed and tagged, so newly ripped albums are tagged automatically.

Note that adding `replaygain` to `ACTIONS` does **not** work with this configuration: `abcde` runs `do_replaygain` *before* `post_encode` and against the pre-rename paths, and `post_encode` then tags each file with `metaflac --remove-all-tags` — which would wipe the gains moments after computing them.

### Albums that were already ripped

```shell
# List FLAC albums with no ReplayGain tags
./fix-replaygain.sh --scan

# Tag all of them
sudo ./fix-replaygain.sh --all

# One album
sudo ./fix-replaygain.sh "/mnt/OSDISK/Fujiko Hemming/La Campanella"
```

| Option | Description |
| --- | --- |
| `--scan` | List FLAC albums with no ReplayGain tags and exit |
| `--all` | Tag every FLAC album that has none |
| `--force` | Recalculate albums that already carry tags |
| `--no-refresh` | Do not update the moOde library afterwards |
| `--dry-run` | Show what would happen, change nothing |

Every track of an album is passed to `metaflac` in a single call, which is what makes `REPLAYGAIN_ALBUM_GAIN` correct. An album whose tracks have differing sample rates is skipped with a warning, because `--add-replay-gain` rejects such a set — split those discs into separate folders. Files are made writable for the rewrite and put back to 444 afterwards, and `--preserve-modtime` keeps moOde from treating every track as changed.

The audio is never re-encoded; only tags are added. To undo, `metaflac --remove-replay-gain` on the files.

## Default CD cover

`default-cd-cover.jpg` comes from [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:CD_icon_test.svg) under the [GNU Free Documentation License v1.2](https://commons.wikimedia.org/wiki/Commons:GNU_Free_Documentation_License,_version_1.2). No changes were made.

## What's changed in this fork (v2.0)

The original project was built for moOde v6.5.0 on Raspberry Pi 3. Since then, moOde has undergone significant changes. This fork addresses the following compatibility issues:

- **Dynamic user detection**: The default `pi` user was removed in moOde 8.3+. The user is now detected automatically via `SUDO_USER`, `LOGNAME`, or `getent`.
- **moOde 10.x detection**: moOde detection now checks for `playback.php` in addition to the legacy `moode.php`.
- **Storage path**: Default rip destination changed from `~/Music-CD/` to `/mnt/OSDISK/` (configurable), the standard music storage location on moOde 10.
- **Debian Trixie compatibility**: Command paths updated from `/bin/*` to `/usr/bin/*` (on Debian Trixie, `/bin` is a symlink to `/usr/bin`).
- **Volume control fallback**: Falls back to `mpc volume` when `rotvol.sh` is not available on newer moOde versions.
- **WebUI library update**: After ripping, the moOde WebUI library update is triggered automatically via the `music-library.php` API, so new albums and cover art appear without manual intervention.
- **Library cache handling**: The `libcache.json` truncation is guarded with a file existence check, as this file no longer exists on moOde 10.
- **Service file templates**: Systemd service files use `.service.in` templates to prevent `git pull` from overwriting configured paths.
- **Volume normalization**: `fix-replaygain.sh` adds ReplayGain tags to FLAC albums, automatically after each rip and retroactively for the existing library. FLAC only by design, so DSD keeps its bit-perfect path. See [Volume normalization](#volume-normalization-flac-only).
- **Album artwork**: `abcde` only reaches CoverArtArchive when a MusicBrainz id was found, so CDDB-identified discs frequently ended up with the placeholder cover. `fix-cover.sh` adds the iTunes and Discogs catalogues, is called automatically when a rip finds no cover, and can assign artwork to albums that were ripped earlier. See [Album artwork](#album-artwork).

## License

GNU General Public License v3.0 - see [LICENSE](LICENSE) for details.

Original work (c) 2020 TheMetalHead.
