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
- glyrc, eyeD3
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
sudo ./Install-cd-rip.sh
```

Your `cd-rip-and-or-play.conf` settings will be preserved. The systemd service files are regenerated from templates on each install, so `git pull` will not overwrite your configured paths.

## Usage

Insert the CD into the drive. The CD will be checked to see if it has been previously ripped. If not, the ripping process will take about 12 minutes. After this, the CD will be ejected and moOde will play the ripped files. If the CD has been previously ripped, it will be ejected and moOde will play the ripped files. More CDs can be inserted for batch queueing.

Cover art is automatically fetched from MusicBrainz/CoverArtArchive and embedded in each track.

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

## License

GNU General Public License v3.0 - see [LICENSE](LICENSE) for details.

Original work (c) 2020 TheMetalHead.
