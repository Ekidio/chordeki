#!/usr/bin/env python3
"""CHORDEKI engine: beats, bars, tempo, key and chords of a song.

Usage: chords.py <song file> [--wav <out.wav>]
Prints JSON lines on stdout: {"progress": 0..1, "step": "..."} while working,
then {"result": {...}} at the end. --wav also writes a playable 16-bit WAV of the song
(for formats AVFoundation cannot play, e.g. WEBM).
"""
import json
import sys
import warnings

warnings.filterwarnings("ignore")

import numpy as np

SR = 22050
HOP = 512

# Chord types: intervals above the root
QUALITIES = {
    '': [0, 4, 7],
    'm': [0, 3, 7],
    '7': [0, 4, 7, 10],
    'maj7': [0, 4, 7, 11],
    'm7': [0, 3, 7, 10],
    'sus2': [0, 2, 7],
    'sus4': [0, 5, 7],
    'add9': [0, 2, 4, 7],
    'dim': [0, 3, 6],
    'm7b5': [0, 3, 6, 10],
    'aug': [0, 4, 8],
}
# Pass 1 finds the plain triads; pass 2 refines each run of a triad among these
REFINE_CANDIDATES = {
    '': ['', '7', 'maj7', 'sus2', 'sus4', 'add9', 'aug'],
    'm': ['m', 'm7', 'dim', 'm7b5', 'sus2', 'sus4'],
}
# Handicap for richer chords, so plain triads win unless the extra tone is clearly there
COMPLEXITY_PENALTY = {
    '': 0, 'm': 0, '7': 0.03, 'm7': 0.03, 'maj7': 0.04, 'sus2': 0.05, 'sus4': 0.05,
    'add9': 0.05, 'dim': 0.06, 'm7b5': 0.06, 'aug': 0.07,
}
# Chance of a chord change on a beat, by its place in the bar
CHANGE_ON_DOWNBEAT = 0.30
CHANGE_ON_HALF_BAR = 0.10
CHANGE_ON_OTHER_BEAT = 0.02

MAJOR_PROFILE = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MINOR_PROFILE = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])


def emit(**kw):
    print(json.dumps(kw), flush=True)


def progress(p, step):
    emit(progress=round(p, 3), step=step)


def decode(path, wav_out=None):
    """Decodes any audio (WEBM, MP3, M4A, ...) with PyAV. Returns mono float32 at SR."""
    import av
    import soxr
    chunks, rate = [], None
    with av.open(path) as f:
        stream = f.streams.audio[0]
        resampler = av.AudioResampler(format='flt', layout='stereo', rate=stream.rate or 44100)
        for frame in f.decode(stream):
            for out in resampler.resample(frame):
                chunks.append(out.to_ndarray().reshape(-1, 2))
                rate = out.sample_rate
        for out in resampler.resample(None):
            chunks.append(out.to_ndarray().reshape(-1, 2))
    if not chunks:
        raise ValueError('No audio found in the file.')
    stereo = np.concatenate(chunks).astype(np.float32)
    if wav_out:
        import soundfile as sf
        sf.write(wav_out, stereo, rate, subtype='PCM_16')
        emit(wav=wav_out)          # the app can start playing now
    mono = stereo.mean(axis=1)
    return soxr.resample(mono, rate, SR).astype(np.float32), mono, rate


FPS = 50   # Beat This! frame rate


def beat_activations(mono, rate):
    """Beat and downbeat probabilities per frame (50 fps) from Beat This! (JKU Linz, MIT)."""
    import torch
    from beat_this.inference import Audio2Frames
    a2f = Audio2Frames(checkpoint_path='final0', device='cpu')
    with torch.no_grad():
        beat_logits, down_logits = a2f(mono, rate)
    sig = lambda x: 1 / (1 + np.exp(-x.cpu().numpy().astype(np.float64)))
    return sig(beat_logits), sig(down_logits)


def estimate_tempo(beat_act):
    """Tempo (BPM) from the periodicity of the beat activation, leaning toward ~100 BPM so that
    eighth-note pulses are not mistaken for beats."""
    a = beat_act - beat_act.mean()
    n = len(a)
    spec = np.fft.rfft(a, 2 * n)
    ac = np.fft.irfft(spec * np.conj(spec))[:n]
    lags = np.arange(int(FPS * 60 / 200), int(FPS * 60 / 50) + 1)
    bpm = 60 * FPS / lags
    prior = np.exp(-0.5 * (np.log2(bpm / 100) / 0.9) ** 2)
    k = int(np.argmax(ac[lags] * prior))
    lag = float(lags[k])
    if 0 < k < len(lags) - 1:                       # parabolic refinement
        y0, y1, y2 = ac[lags[k] - 1], ac[lags[k]], ac[lags[k] + 1]
        den = y0 - 2 * y1 + y2
        lag += 0.5 * (y0 - y2) / den if den else 0
    return 60 * FPS / lag


def track_beats(beat_act, bpm):
    """Steady beats at the given tempo, following the activation peaks (dynamic programming)."""
    import librosa
    _, frames = librosa.beat.beat_track(onset_envelope=beat_act, sr=SR, hop_length=SR // FPS,
                                        bpm=bpm, tightness=300, trim=False)
    times = []
    for f in frames:                                 # sub-frame peak position
        if 0 < f < len(beat_act) - 1:
            y0, y1, y2 = beat_act[f - 1], beat_act[f], beat_act[f + 1]
            den = y0 - 2 * y1 + y2
            off = 0.5 * (y0 - y2) / den if den else 0
            times.append((f + float(np.clip(off, -0.5, 0.5))) / FPS)
        else:
            times.append(f / FPS)
    return np.array(times)


def bar_positions(beats, down_act):
    """Meter (3 or 4) and each beat's place in its bar (0 = downbeat).

    A small HMM over the beats: the position advances by one each beat, and may rarely start a
    new bar early (a shortened bar), scored by the downbeat probability at each beat."""
    idx = np.clip(np.round(beats * FPS).astype(int), 0, len(down_act) - 1)
    d = np.clip(np.array([down_act[max(0, i - 2):i + 3].max() for i in idx]), 0.01, 0.99)

    def decode(m):
        logp_down, logp_not = np.log(d), np.log(1 - d)
        eps = 1e-3
        T = len(d)
        score = np.full(m, np.log(1 / m))
        back = np.zeros((m, T), dtype=int)
        score = score + np.where(np.arange(m) == 0, logp_down[0], logp_not[0])
        for t in range(1, T):
            new = np.full(m, -np.inf)
            for k in range(m):
                nxt = (k + 1) % m
                cand = score[k] + np.log(1 - eps)
                if cand > new[nxt]:
                    new[nxt], back[nxt, t] = cand, k
                if nxt != 0:                         # early new bar
                    cand = score[k] + np.log(eps)
                    if cand > new[0]:
                        new[0], back[0, t] = cand, k
            score = new + np.where(np.arange(m) == 0, logp_down[t], logp_not[t])
        path = np.zeros(T, dtype=int)
        path[-1] = int(np.argmax(score))
        for t in range(T - 1, 0, -1):
            path[t - 1] = back[path[t], t]
        return path, float(np.max(score))

    best = None
    for m, bias in ((4, 0.0), (3, -0.02 * len(d))):   # lean toward 4/4
        path, ll = decode(m)
        if best is None or ll + bias > best[2]:
            best = (path, m, ll + bias)
    return best[0], best[1]


def template(root, quality):
    v = np.zeros(12)
    for i, iv in enumerate(QUALITIES[quality]):
        v[(root + iv) % 12] = 1.0 if i == 0 else 0.85 if i < 3 else 0.75
    return v / np.linalg.norm(v)


def viterbi(emission, change_prob):
    """emission: (states, T) probabilities; change_prob[t]: chance to leave a state at step t."""
    n, T = emission.shape
    logE = np.log(emission + 1e-12)
    score = logE[:, 0].copy()
    back = np.zeros((n, T), dtype=int)
    for t in range(1, T):
        p = change_prob[t]
        stay, move = np.log(1 - p), np.log(p / (n - 1))
        # Best predecessor among the *other* states: the top one, or the runner-up for the top state itself
        order = np.argsort(score)
        top, second = order[-1], order[-2]
        other = np.full(n, top)
        other[top] = second
        from_other = score[other] + move
        stay_score = score + stay
        use_other = from_other > stay_score
        back[:, t] = np.where(use_other, other, np.arange(n))
        score = np.where(use_other, from_other, stay_score) + logE[:, t]
    path = np.zeros(T, dtype=int)
    path[-1] = int(np.argmax(score))
    for t in range(T - 1, 0, -1):
        path[t - 1] = back[path[t], t]
    return path


def refine(root, base, cols, change_prob):
    cands = REFINE_CANDIDATES[base]
    c = cols / (cols.max(axis=0, keepdims=True) + 1e-9)
    c = 0.5 * c + 0.5 * c.mean(axis=1, keepdims=True)          # resist melody notes
    c = c / (np.linalg.norm(c, axis=0, keepdims=True) + 1e-9)
    T = np.array([template(root, q) for q in cands])
    scores = T @ c - np.array([COMPLEXITY_PENALTY[q] for q in cands])[:, None]
    probs = np.exp(scores * 60)
    probs /= probs.sum(axis=0, keepdims=True)
    return [cands[k] for k in viterbi(probs, change_prob)]


REPEAT_BLOCK = 4          # bars compared at a time
REPEAT_SIMILAR = 0.88     # how alike two 4-bar stretches must sound to count as the same music


def repeats(S, bars):
    """For every bar, the other bars that are the same music. Found by sound, not by chord names,
    so a mistake in one verse can be fixed from another. S: bar-to-bar similarity of their harmony."""
    n = len(S)

    def block(i, j):
        k = min(REPEAT_BLOCK, n - i, n - j)
        return float(np.mean([S[i + t, j + t] for t in range(k)])) if k > 0 else 0.0

    twins = [set() for _ in range(n)]
    for i in range(n):
        for j in range(i + REPEAT_BLOCK, n):
            if block(i, j) >= REPEAT_SIMILAR:
                for t in range(min(REPEAT_BLOCK, n - j)):
                    if S[i + t, j + t] >= 0.8 and len(bars[i + t]) == len(bars[j + t]):
                        twins[i + t].add(j + t)
                        twins[j + t].add(i + t)
    return [sorted(t) for t in twins]


def structure(S_harmony, timbre, level, first):
    """A suggestion for the song's sections: where the sound turns (harmony + sound colour + level),
    which parts are the same music, and names for them (INTRO, VERSE, CHORUS, BRIDGE, OUTRO).
    Returns [{'bar': first bar of the section, 'kind': name}]. Meant to be checked and edited by hand."""
    n = len(S_harmony)
    if n - first < 8:
        return []
    t = (timbre - timbre.mean(0)) / (timbre.std(0) + 1e-9)
    t /= np.linalg.norm(t, axis=1, keepdims=True) + 1e-9
    S = 0.55 * S_harmony + 0.45 * (t @ t.T + 1) / 2

    # Novelty: how different the 4 bars after a bar line are from the 4 before it
    k = 4
    score = np.zeros(n)
    for i in range(k, n - k + 1):
        before, after, across = S[i - k:i, i - k:i].mean(), S[i:i + k, i:i + k].mean(), S[i - k:i, i:i + k].mean()
        score[i] = (before + after) / 2 - across
    for i in range(2, n - 2):
        score[i] += 0.01 * abs(level[i:i + 2].mean() - level[i - 2:i].mean())

    cand = [i for i in range(first + 2, n - 1)
            if score[i] >= score[max(0, i - 2):i + 3].max() and score[i] > np.percentile(score[first:], 60)]
    snapped = []
    for i in cand:                      # sections start on the 4-bar grid when that is nearly as good
        best = i
        for j in (i - 1, i + 1):
            if (j - first) % 4 == 0 and score[j] >= 0.8 * score[i]:
                best = j
        snapped.append(best)
    bounds = []
    for i in sorted(set(snapped), key=lambda i: -score[i]):
        if all(abs(i - b) >= 4 for b in bounds) and i - first >= 4 and n - i >= 2:
            bounds.append(i)
    starts = [first] + sorted(bounds)
    segs = [(a, starts[j + 1] if j + 1 < len(starts) else n) for j, a in enumerate(starts)]

    # The same music gets the same letter
    def alike(a, b):
        m = min(a[1] - a[0], b[1] - b[0])
        return float(np.mean([S[a[0] + x, b[0] + x] for x in range(m)])) if m else 0.0
    letters = []
    for j, sg in enumerate(segs):
        same = next((letters[i] for i in range(j) if alike(segs[i], sg) >= 0.80), None)
        letters.append(same or chr(65 + len(set(letters))))

    song_level = float(np.median(level[first:]))
    count = {l: letters.count(l) for l in letters}
    bars_of = {l: sum(b - a for (a, b), x in zip(segs, letters) if x == l) for l in count}
    repeated = [l for l in count if count[l] >= 2]
    verse = max(repeated, key=lambda l: (bars_of[l], -letters.index(l))) if repeated else None
    loud = {l: np.mean([level[a:b].mean() for (a, b), x in zip(segs, letters) if x == l]) for l in count}
    others = [l for l in repeated if l != verse]
    chorus = max(others, key=lambda l: loud[l]) if others else None

    kinds = []
    for j, ((a, b), l) in enumerate(zip(segs, letters)):
        if l == verse:
            kind = 'VERSE'
        elif l == chorus:
            kind = 'CHORUS'
        elif j == 0 and count[l] == 1:
            kind = 'INTRO'
        elif j >= len(segs) - 2 and level[a:b].mean() < song_level - 3:
            kind = 'OUTRO'
        else:
            kind = 'BRIDGE'
        kinds.append(kind)
    # Neighbouring parts of the same kind that are not repeats of each other become one section
    # (verses and choruses that repeat stay separate: VERSE 1, VERSE 2…)
    out = []
    for j, ((a, b), kind) in enumerate(zip(segs, kinds)):
        if out and out[-1]['kind'] == kind and kind in ('BRIDGE', 'OUTRO', 'INTRO'):
            continue
        out.append({'bar': int(a), 'kind': kind})
    return out


def detect_key(chroma_mean):
    best = (-np.inf, 0, 'major')
    for root in range(12):
        for mode, profile in (('major', MAJOR_PROFILE), ('minor', MINOR_PROFILE)):
            r = np.corrcoef(chroma_mean, np.roll(profile, root))[0, 1]
            if r > best[0]:
                best = (r, root, mode)
    return best[1], best[2]


def analyze(path, wav_out=None):
    import librosa

    progress(0.02, 'Reading the song')
    y, mono, rate = decode(path, wav_out)
    duration = len(y) / SR
    if duration < 3:
        raise ValueError('The song is too short.')

    progress(0.15, 'Finding beats and bars')
    beat_act, down_act = beat_activations(mono, rate)
    tempo = estimate_tempo(beat_act)
    beats = track_beats(beat_act, tempo)
    beats = beats[(beats >= 0) & (beats < duration)]
    if len(beats) < 8:
        beats = np.arange(0, duration, 60 / tempo)
    pos, meter = bar_positions(beats, down_act)
    tempo = 60.0 / float(np.median(np.diff(beats)))

    progress(0.55, 'Listening to the harmony')
    y_harm = librosa.effects.harmonic(y, margin=2)
    chroma = librosa.feature.chroma_cqt(y=y_harm, sr=SR, hop_length=HOP, bins_per_octave=36)
    bass = librosa.feature.chroma_cqt(y=y_harm, sr=SR, hop_length=HOP, bins_per_octave=36,
                                      fmin=librosa.note_to_hz('E1'), n_octaves=2)
    rms = librosa.feature.rms(y=y, hop_length=HOP)[0]
    mfcc = librosa.feature.mfcc(y=y, sr=SR, hop_length=HOP, n_mfcc=13)
    n_frames = chroma.shape[1]

    progress(0.8, 'Naming the chords')
    # One column per interval: [0, beat 1), [beat 1, beat 2), ..., [last beat, end)
    edges = np.concatenate([[0.0], beats, [duration]])
    has_pickup = beats[0] > 0.05                  # an interval before the first beat
    if not has_pickup:
        edges = edges[1:]
    off = 1 if has_pickup else 0
    fr = np.clip(np.round(edges * SR / HOP).astype(int), 0, n_frames)

    def sync(feat, agg):
        return np.stack([agg(feat[:, a:max(b, a + 1)], axis=1) if a < n_frames else feat[:, -1]
                         for a, b in zip(fr[:-1], fr[1:])], axis=1)

    seg_chroma = sync(chroma, np.median)
    seg_bass = sync(bass, np.median)
    seg_rms = sync(rms[np.newaxis, :n_frames], np.mean)[0]

    # Pass 1: 24 triads + N, scored by the full chroma plus a bonus when the bass plays the root
    labels = [(r, q) for q in ('', 'm') for r in range(12)]
    T = np.array([template(r, q) for r, q in labels])
    norm = np.linalg.norm(seg_chroma, axis=0, keepdims=True) + 1e-9
    bass_n = seg_bass / (seg_bass.max(axis=0, keepdims=True) + 1e-9)
    sim = T @ (seg_chroma / norm) + 0.12 * np.array([bass_n[r] for r, _ in labels])
    probs = np.exp(sim * 25)
    probs /= probs.sum(axis=0, keepdims=True)
    # No chord: very quiet, or fairly quiet and not really like any chord (an intro, a fade, noise)
    loud = seg_rms / (np.median(seg_rms) + 1e-9)
    best_fit = (T @ (seg_chroma / norm)).max(axis=0)
    very_quiet = np.clip(1.0 - loud / 0.15, 0, 1)
    unclear = np.clip(1.0 - loud / 0.5, 0, 1) * np.clip((0.68 - best_fit) / 0.15, 0, 1)
    p_none = np.clip(np.maximum(very_quiet, unclear), 0.02, 0.98)
    emission = np.vstack([probs * (1 - p_none), p_none])

    n_seg = emission.shape[1]
    change = np.full(n_seg, CHANGE_ON_OTHER_BEAT)
    half = meter // 2 if meter % 2 == 0 else None
    for i in range(n_seg):
        b = i - off
        if b < 0:
            continue
        if pos[b] == 0:
            change[i] = CHANGE_ON_DOWNBEAT
        elif half is not None and pos[b] == half:
            change[i] = CHANGE_ON_HALF_BAR
    states = viterbi(emission, change)

    chords = []
    for i in range(n_seg):
        root, base = (None, '') if states[i] == len(labels) else labels[states[i]]
        chords.append({'root': root, 'base': base, 'quality': base})

    # Pass 2: within each run of one triad, find the chord type (7ths, sus, dim, ...)
    i = 0
    while i < n_seg:
        j = i
        while j + 1 < n_seg and (chords[j + 1]['root'], chords[j + 1]['base']) == (chords[i]['root'], chords[i]['base']):
            j += 1
        if chords[i]['root'] is not None:
            qs = refine(chords[i]['root'], chords[i]['base'], seg_chroma[:, i:j + 1], change[i:j + 1])
            for k, q in zip(range(i, j + 1), qs):
                chords[k]['quality'] = q
        i = j + 1

    key_root, key_mode = detect_key(chroma.mean(axis=1))

    # How sure we are of each beat's chord: its share of the evidence at that beat.
    conf = emission[states, np.arange(n_seg)] / (emission.sum(axis=0) + 1e-12)

    out_beats = []
    for b in range(len(beats)):
        c = chords[b + off]
        out_beats.append({'t': round(float(beats[b]), 4), 'pos': int(pos[b]), **c,
                          'conf': round(float(conf[b + off]), 3)})

    # Bars as the app groups them (a new bar on every 1; a pickup bar first if the song starts mid-bar)
    bars = []
    for b in range(len(beats)):
        if pos[b] == 0 or not bars:
            bars.append([])
        bars[-1].append(b)
    feats = []
    for bar in bars:
        f = np.zeros((meter, 12))
        for b in bar:
            col = seg_chroma[:, b + off]
            f[min(meter - 1, pos[b])] = col / (col.max() + 1e-9)
        f = f.ravel()
        feats.append(f / (np.linalg.norm(f) + 1e-9))
    F = np.array(feats)
    S = F @ F.T
    twins = repeats(S, bars)

    # Sound colour and level of every bar, for finding the song's sections
    starts_t = [float(beats[bar[0]]) for bar in bars] + [duration]
    timbre, level = [], []
    for i in range(len(bars)):
        a = min(n_frames - 1, int(starts_t[i] * SR / HOP))
        e = max(a + 1, min(n_frames, int(starts_t[i + 1] * SR / HOP)))
        timbre.append(mfcc[1:, a:e].mean(axis=1))
        level.append(20 * np.log10(rms[a:e].mean() + 1e-9))
    first_full = 1 if bars and pos[bars[0][0]] != 0 else 0
    sections = structure(S, np.array(timbre), np.array(level), first_full)

    # The accompaniment's rhythm: note starts in the harmonic part, mid range (drums and bass left out),
    # for MIDI chords that play when the band plays. [time, strength 0..1]
    env = librosa.onset.onset_strength(y=y_harm, sr=SR, hop_length=HOP, fmin=150, fmax=3000, n_mels=64)
    on = librosa.onset.onset_detect(onset_envelope=env, sr=SR, hop_length=HOP, units='frames', backtrack=False, delta=0.08)
    top = float(env[on].max()) if len(on) else 1.0
    onsets = [[round(float(t), 3), round(float(v) / top, 2)]
              for t, v in zip(librosa.frames_to_time(on, sr=SR, hop_length=HOP), env[on])]
    pickup = chords[0] if has_pickup else None

    progress(1.0, 'Done')
    return {
        'duration': round(duration, 3),
        'tempo': round(tempo, 2),
        'meter': meter,
        'key': {'root': key_root, 'mode': key_mode},
        'beats': out_beats,
        'pickup': pickup,
        'bar_twins': twins,
        'sections': sections,
        'onsets': onsets,
    }


def main():
    args = sys.argv[1:]
    wav_out = None
    if '--wav' in args:
        k = args.index('--wav')
        wav_out = args[k + 1]
        del args[k:k + 2]
    try:
        emit(result=analyze(args[0], wav_out))
    except Exception as e:  # reported to the app
        emit(error=str(e))
        sys.exit(1)


if __name__ == '__main__':
    main()
