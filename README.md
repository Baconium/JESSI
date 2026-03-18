<div align="center">
  <br>
  <a href="https://discord.gg/aZ9HbYXKur"><img src="https://raw.githubusercontent.com/rooootdev/JESSI/main/gay2_electricboogaloo.png" alt="JESSI Logo" width="200"></a>
  <br>
  <h1>JESSI</h1>
</div>

<h4 align="center">Java Edition Servers Suck on iOS</h4>

<p align="center">
  <a href="https://discord.gg/aZ9HbYXKur">
    <img src="https://img.shields.io/badge/Discord-Join%20Server-7289DA.svg" alt="Discord">
  </a>
  <a href="https://github.com/baconium/JESSI/stargazers">
    <img src="https://img.shields.io/github/stars/baconium/JESSI?style=social" alt="GitHub stars">
  </a>
  <a href="https://github.com/baconium/JESSI/issues">
    <img src="https://img.shields.io/github/issues/baconium/JESSI" alt="GitHub issues">
  </a>
  <a href="https://github.com/baconium/JESSI/releases">
    <img src="https://img.shields.io/github/v/release/baconium/JESSI" alt="Release">
  </a>
</p>

<p align="center">
  <a href="#basic-information">Basic Information</a> •
  <a href="#livecontainer">LiveContainer</a> •
  <a href="#features">Features</a> •
  <a href="#buildingmiscellaneous-extra-info">Build / Misc</a>
</p>

If you would like support, want to request a feature, or just talk to other JESSI users you should join the discord: https://discord.gg/aZ9HbYXKur

# Basic Information

JESSI is an iOS app that runs Minecraft: Java Edition servers natively on iOS, targeting iOS 14+. JESSI runs on both jailed and jailbroken iOS, only requiring JIT to do so.

JESSI was designed specifically to be as easy to use as possible, even if you have never hosted a Minecraft server before. The UI is simple to understand and use, making JESSI the best beginner friendly option to host a minecraft server.

Tutorials for installing JESSI can be found in [the wiki for this repo](https://github.com/Baconium/JESSI/wiki). More tutorials for specific features will be coming shortly, as well as video tutorials!

# LiveContainer

While this repo won't directly give you a guide on how to use/install LiveContainer, it should be noted that JESSI has full compatibility with LiveContainer. All you need to do is install JESSI inside of LiveContainer, then launch it with JIT.

# Features

JESSI is still being actively developed, and plenty of more features will come. Here's a list of some of JESSI's most important features:

- Ability to run minecraft servers (duh)
- Built in JVM downloader, pick between Java 8, 17, and 21 (or download all of them!)
- Server memory allocation slider
- Easy to use server creator, with support for several server softwares
- A file manager that allows you to easily manage several servers
- Network tunneling via playit.gg and UPnP support
- Integrated mod, modpack, resource pack, and datapack downloading via Modrinth and curseforge
- Keep alive, run the server in the background even with the screen off
- Server config GUI

# Building/Miscellaneous extra info

If you would like to build JESSI yourself, it's pretty simple. Install Xcode and Xcode CLI, then run one of the following:

- `scripts/build-ipa.sh` for iOS IPA output
- `scripts/build-ipa.sh --macos` for a macOS (Mac Catalyst) `.app` output in `dist/`

There are some limitations that we're currently running into for jailed iOS, that we're not sure are solvable. The main one is that the JVM must run in the same process as the app itself. Because of this, when the JVM is killed in any way, the app is also killed. So, at least for now, if you stop a server or create a forge/neoforge server in the server setup, the app will crash after the java process ends. You will not lose any data from a crash occuring this way, and in fact Crash Reporter on iOS doesn't even detect it as a crash. This is solvable by running the JVM in a seperate process, which is now automatically used for macOS builds and still available on supported TrollStore setups.

We're open to feedback and suggestions for features, so if you have any ideas on how JESSI could be improved feel free to contact us in the discord server. Thank you for using JESSI!
