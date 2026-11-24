# Jarvis Daily Brief prototype

Open `prototypes/jarvis/index.html` in a browser from a checkout of this branch. It runs offline with the included fictional reports, illustration and audio.

Expand **Jarvis** in the sidebar. **Daily Brief** plays the sample narration and shows its transcript. **Overnight tasks** opens the dated reports. The Chicago internship report links to its sources, the list delivered that morning and a later edit. The microphone report shows a research-only task. **Audio options** accepts a recording from your device, including a saved ElevenLabs clip.

## Iterating

Edit `reader.css` for layout or `reader.js` for behavior, then refresh the browser. Edit `frame.html` for the document shell and `fixtures/` for the Markdown. After changing the shell, fixtures or sidebar generator, rebuild the checked-in HTML from the repository root with Python 3, Pillow and Pandoc on your path.

```sh
python3 prototypes/jarvis/build.py
```

The sidebar glyphs and font come from the public Mac app. The orb is a still of its dithered shader. The report uses an original generated lakefront illustration. The included audio is the fictional November 24 script spoken by eSpeak NG. Live scheduling, native Mac integration and ElevenLabs generation are outside this browser prototype.
