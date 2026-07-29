# Dragon Ball Sparking Zero — Accessibility Mod

**A mod that makes the game talk, so it can be played without sight.**

![Version](https://img.shields.io/badge/version-1.1.0-blue)
![System](https://img.shields.io/badge/system-Windows-lightgrey)
![Screen reader](https://img.shields.io/badge/screen%20reader-NVDA%20and%20compatible-green)
![Status](https://img.shields.io/badge/status-active%20development-orange)

[Leer en español](README.md)

## Downloads

Three ways to get it. All three install exactly the same thing.

**1. All in one, the simplest:** [InstalarModCompleto.exe](../../releases/latest)

A single file. Open it, click Next, click Install, done. The mod is bundled inside, so
there is nothing else to download or unzip.

**2. The full package:** [ModSparkingZero.zip](../../releases/latest)

Unzip it and you get the instructions, the installer and, if you would rather not run any
executable at all, an `instalar.bat` that does the same job without any security warning.

**3. Just the instructions:** [LEEME.txt](LEEME.txt) — currently in Spanish.

## Why this exists

DRAGON BALL Sparking! ZERO ships with no accessibility options. If you cannot see the
screen, there is no way to know which menu option you are on, how much health you have
left, what a character is saying in a cutscene, or who you just unlocked.

This mod exists for that reason: to be able to play. It is built by playing, getting it
wrong, and trying again, with real matches as the test bench. It is not a polished
commercial product — it is a tool that grows through use.

## What it reads

- **Menus**: every option as you move, including submenus, Settings and their values
  (automatic, semi-automatic, off, volume levels...).
- **Combat**: health, ki, transformations, beam and melee clashes, and the characters'
  attack shouts.
- **Story**: cutscene and dialogue subtitles, the episode map with its nodes, chapters and
  conditions, and the details of each battle.
- **Rewards**: what you earn after a match, level ups and unlocks.
- **The Encyclopedia**: each character's name, categories and four techniques. It even
  tells apart two characters that share the same name.
- **The Shop**: tabs, categories and items.
- **Tournaments**: announcer, bracket between rounds, prizes and menus.
- **The pause menu** and the command and move list.

## Accessibility

It speaks on its own, with no need to have a screen reader window open. Tested daily with
**NVDA** on Windows 11, and it uses UniversalSpeech, so other compatible readers work too.

The installer is an ordinary wizard, the usual kind: it reads fine with a screen reader
and you just keep pressing Next.

## Installation

1. Download the package and unzip it wherever you like.
2. Run `InstalarModCompleto.exe`. It finds the game folder on its own and copies
   everything into place.
3. Launch the game. It will start talking as soon as it reaches the title screen.

Windows will warn that it protected your PC. That happens with any program without a paid
digital signature. Choose "More info" and then "Run anyway". If you would rather avoid it,
the package includes `instalar.bat`, which does the same without any warning, and you can
also copy the files by hand.

To uninstall, delete `dwmapi.dll` from the game folder.

## Keys

- **F6** repeats the last rewards.
- **F7** repeats the details of the last story map node.

## What's new

**Version 1.1.0** — the Encyclopedia can now be browsed end to end: it reads each
character's name, their categories and their four techniques, and it tells apart two
characters that share a name. Settings now speak the value of each option as you move
through them, with no need to leave and come back. Reading was added for the Shop and the
tournament menus. And under the hood the reader is noticeably lighter: menus that used to
stall now respond.

The full history, version by version, is in [CHANGELOG.md](CHANGELOG.md).

## Project status, honestly

It works and it is used every day, but it is **not finished**. The game can still crash on
some screen transitions, and in places the reader is slower than it should be. Work
continues and every version closes a few more cases.

The mod reads the interface by querying the game's own elements at runtime. That means a
**major game update may break it** until it is adapted.

The mod stores nothing on your computer and sends nothing anywhere: it just reads the
screen and speaks.

## Contributing

You may use, share and modify this mod freely. If you improve it, you can publish your
changes and also propose them here so they become part of the main project.

Open a pull request and it will be reviewed; if it fits, it gets merged with credit to
whoever wrote it. Nothing is merged without review and approval.

To report a bug, open an issue: there is a template that walks you through it. Telling us
which screen you were on and what you were doing is usually enough to track it down.

## Credits

This mod has passed through several hands, and the order matters:

1. **Jessica Tegner** and **[Access Forge](https://github.com/AccessForge/SparkingZeroAccess)**
   — original creation of the mod, April 2026. The whole foundation everything else was
   built on: the speech bridge, menu reading, the combat HUD and subtitles.
2. **Iván (ivanack123)** — continuation and development from July 2026: Encyclopedia,
   Settings values, Shop, tournaments, story map, performance work and the hunt for the
   crashes.
3. **And whoever comes next.** If you contribute, your name goes here.

Made by and for the community of blind players.

## License

[MIT License](LICENSE). You may use, modify and redistribute it, including your own
changes, as long as the credits and the license notice are kept.

Bundles UE4SS and UniversalSpeech, which carry their own licenses and belong to their
respective authors. This project is not affiliated with, maintained or sponsored by Bandai
Namco or Spike Chunsoft. DRAGON BALL Sparking! ZERO belongs to its rights holders.
