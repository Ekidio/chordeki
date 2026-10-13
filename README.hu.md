# CHORDEKI – akkordok · beatek · midi

[🇬🇧 English](README.md) · 🇭🇺 Magyar

**▶ Weboldal:** [ekidio.github.io/chordeki/hu](https://ekidio.github.io/chordeki/hu/) · **⬇ Letöltés:** [legújabb kiadás (DMG)](https://github.com/Ekidio/chordeki/releases/latest)

![CHORDEKI](docs/assets/chordeki-main.png)

A **CHORDEKI** meghallgat egy dalt, és a beatrácsra leírja az akkordjait, mint a Chordify. Utána fülre ellenőrizheted, gyorsan javíthatod, és MIDI-ként vagy nyomtatható akkordlapként viheted tovább.

Natív macOS app (Swift, Apple Silicon). Az elemzés a gépeden fut, egy betanított beatfelismerővel (Beat This!) és a librosával – a zenéd nem hagyja el a Macet.

A CHORDEKI egy **EKIDIO SOUND** app. Lásd még: [STEMEKI](https://github.com/Ekidio/stemeki) · [PADEKI](https://github.com/Ekidio/padeki).

## Tudja

- **Bármilyen dal:** MP3, WAV, AIFF, M4A, FLAC, WEBM (⌘O vagy behúzás az ablakra).
- **Beat és ütemek:** minden beat és az „egy”, tempó, ütemmutató, hangnem.
- **Akkordok beatre:** dúr/moll, vagy bővített (7, maj7, m7, sus2, sus4, add9, dim, m7b5, aug). SIMPLE / EXTENDED kapcsoló, transzponálás.
- **Együttjátszás:** a dalt követő akkordrács, NOW / NEXT gitárfogással, metronóm (CLICK) a felismert beatekre.
- **Fülre ellenőrzés:** bármelyik akkordra kattintva megszólal zongorán. A **PIANO** a zenével együtt játssza az akkordokat (MIX: eredeti ↔ zongora); bekapcsolva a ←/→ akkordról akkordra lép.
- **Bizonytalan akkordok:** ahol a motor nem biztos, jelölve van; **U** a következőre ugrik, **O** jóváhagyja.
- **Gyors javítás:** kijelölés (kattintás, Shift+kattintás), akkord a dal akkordjai közül vagy bármelyik, ⌫ törli (az előző szól tovább), ⌘C / ⌘V egész szakaszt másol, ⌘Z visszavon.
- **Dalszerkezet:** INTRO, VERSE, CHORUS, BRIDGE, OUTRO… fülre javasolva és szerkeszthetően (jobb klikk → Section Starts Here); a rács minden részt új sorban kezd, a hullámformán színesen látszanak, és bekerülnek a PDF-be és cue-markerként a MIDI-be.
- **Gitár vagy zongora:** minden akkord gitárfogásként vagy zongora-billentyűzeten (GUITAR / PIANO), a PDF-ben is.
- **Újraütés:** kitartott akkord bármelyik beaten újrakezdhető – a MIDI-ben új hang, nem kell vágni a DAW-ban.
- **Ugyanaz a zene máshol:** a CHORDEKI hallja, mely ütemek ugyanazok; javítás után felajánlja, hogy ott is javítsa (**A**).
- **Római vagy Nashville:** az akkordnevek betűvel (ABC), vagy a hangnem fokszámaiként – római (i, bVII, iv, V7) vagy Nashville (1m, b7, 4m, 5⁷) – a rácsban, a NOW / NEXT panelen és a PDF-ben.
- **MIDI a dal ritmusában:** bekapcsolt **RHYTHM** mellett a MIDI akkordsávja ott szól, ahol a felvétel kísérete játszik (tizenhatodra igazítva, a dinamikájával), kitartott akkordok helyett.
- **Export:** MIDI **SYNCED** (a tempó követi a felvételt) vagy **GRID** (egyenletes, egész BPM), és **PDF akkordlap** (⌘P).
- Önmagát frissíti (Sparkle).

## Építés

```sh
./build.sh --install     # dist/CHORDEKI.app, és bemásolja a ~/Applications-be
./make-dmg.sh            # telepítő DMG
./make-release.sh        # DMG + Sparkle appcast egy GitHub-kiadáshoz
```

Első indításkor az app egy kattintással telepíti az elemzőmotort (Python, Beat This!, librosa) ide: `~/Library/Application Support/CHORDEKI/Engine`.

© 2026 ekidio
