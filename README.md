# CHORDEKI – chords · beats · midi

🇬🇧 English · [🇭🇺 Magyar](README.hu.md)

**▶ Website:** [ekidio.github.io/chordeki](https://ekidio.github.io/chordeki/) · **⬇ Download:** [latest release (DMG)](https://github.com/Ekidio/chordeki/releases/latest)

![CHORDEKI](docs/assets/chordeki-main.png)

**CHORDEKI** listens to a song and writes down its chords on the beat grid, Chordify-style, then lets you check them by ear, fix them fast and take them anywhere as MIDI or a printable chord sheet.

It's a native macOS app (Swift, Apple Silicon). Analysis runs locally with a trained beat model (Beat This!) and librosa – your music never leaves your Mac.

CHORDEKI is an **EKIDIO SOUND** app. See also: [STEMEKI](https://github.com/Ekidio/stemeki) · [PADEKI](https://github.com/Ekidio/padeki).

## Features

- **Open any song:** MP3, WAV, AIFF, M4A, FLAC, WEBM (⌘O or drop on the window).
- **Beats and bars:** every beat and the 1 of the bar, tempo, meter and key.
- **Chords on the beat:** major / minor, or extended (7, maj7, m7, sus2, sus4, add9, dim, m7b5, aug). SIMPLE / EXTENDED switch, transpose.
- **Play along:** chord grid that follows the song, NOW / NEXT with guitar shapes, metronome CLICK on the detected beats.
- **Check by ear:** click any chord to hear it on the piano. **PIANO** plays the chords along with the song (MIX: original ↔ piano); with PIANO on, ← / → step from chord to chord.
- **Unsure chords:** the ones the engine wasn't sure of are marked; **U** goes to the next one, **O** marks it right.
- **Fix fast:** select beats (click, shift-click), pick a chord from the song's chords or any chord, ⌫ removes one (the chord before goes on), ⌘C / ⌘V copy a whole passage, ⌘Z undo.
- **Song sections:** INTRO, VERSE, CHORUS, BRIDGE, OUTRO… suggested by ear and editable (right-click → Section Starts Here); the grid starts every section on a new row, the waveform shows them in colour, and they go into the PDF and as cue markers into the MIDI.
- **Guitar or piano:** every chord as a guitar shape or on piano keys (GUITAR / PIANO), also in the PDF.
- **Strike again:** a held chord can start again on any beat – a new note in the MIDI, no cutting in the DAW.
- **Same music elsewhere:** CHORDEKI hears which bars are the same music; after a fix it offers to put it there too (**A**).
- **Export:** MIDI **SYNCED** (tempo map follows the recording) or **GRID** (steady whole BPM), and a **PDF chord sheet** (⌘P).
- Updates itself (Sparkle).

## Keys

| Key | |
|---|---|
| Space | play / pause |
| ← / → | a bar back / forward (with PIANO on: chord by chord) |
| Enter | to the start |
| P | hear the chord on the piano |
| J / K | PIANO / CLICK on-off |
| U / ⇧U | next / previous unsure chord |
| O | the chord sounds right |
| A | apply the fix to the same music elsewhere |
| ⌫ | remove the chord |
| ⌘C / ⌘V / ⌘Z | copy / paste / undo chords |
| ⌘E / ⇧⌘E | export MIDI synced / grid |
| ⌘P | export PDF chord sheet |

## Build

```sh
./build.sh --install     # builds dist/CHORDEKI.app and copies it to ~/Applications
./make-dmg.sh            # the installer DMG
./make-release.sh        # DMG + Sparkle appcast for a GitHub release
```

On first launch the app installs its analysis engine (Python, Beat This!, librosa) into `~/Library/Application Support/CHORDEKI/Engine` with one click.

## Credits

Beats: [Beat This!](https://github.com/CPJKU/beat_this) (JKU Linz, MIT). Audio analysis: [librosa](https://librosa.org). Updates: [Sparkle](https://sparkle-project.org).

© 2026 ekidio
