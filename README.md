# Volume Buddy

macOS menu bar app that adds volume control for audio outputs that lack hardware volume support (e.g. monitor headphone jacks over DisplayPort). Routes system audio through [BlackHole](https://github.com/ExistentialAudio/BlackHole) into a selected output device. Volume keys and the native OSD work as normal via BlackHole's virtual volume control.

The menu bar icon lets you pick any connected fixed-volume output device. Your selection is remembered across launches.

## Prerequisites

Volume Buddy requires [BlackHole 16ch](https://github.com/ExistentialAudio/BlackHole) — a free, open-source virtual audio driver for macOS.

**Install via Homebrew:**
```
brew install blackhole-16ch
```

**Or download the installer package** from [existential.audio/blackhole](https://existential.audio/blackhole/).

## How it works

1. On launch, Volume Buddy sets BlackHole 16ch as the system default output device — all system audio flows into it
2. A CoreAudio aggregate device pairs BlackHole (input) with your chosen output device
3. A HAL I/O audio unit bridges the audio from BlackHole to your output device in real time
4. Volume keys and mute work natively via BlackHole's virtual volume control, including the system OSD
5. On quit, the original default output device is restored
