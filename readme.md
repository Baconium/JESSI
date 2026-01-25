If you would like support, want to request a feature, or just talk to other JESSI users you should join the discord: https://discord.gg/aZ9HbYXKur

JESSI is a jailed app that runs Minecraft: Java Edition servers natively on ios, targeting iOS 14+. While JESSI can run on non jailbroken devices, it requires JIT to be enabled in order to actually function.

To enable JIT on iOS 14-17.0, just use trollstore to install JESSI, and JIT will automatically work.

To enable JIT on iOS 17.0.1-17.3.1, good luck!

To enable JIT on iOS 17.4-26.x, you must first install [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) and [StikDebug](https://github.com/StephenDev0/StikDebug). After this, you will need to get your pairing file. Download [Jitterbugpair](https://github.com/osy/Jitterbug) on your computer. Make sure you download Jitterbugpair, not Jitterbug. Then, use it to get your pairing file, and get it to your devices files app. Then, enable the VPN in LocalDevVPN and import the pairing file into StikDebug, and you're ready to enable JIT. Make sure you have JESSI installed, then in StikDebug tap the "Connect by App" button and select JESSI. To make sure JIT is enabled, you can check the settings tab in JESSI.

JESSI also works inside of [LiveContainer](https://github.com/LiveContainer/LiveContainer), however this readme will not provide a setup guide for LiveContainer.

If you would like to build JESSI yourself, it's pretty simple. Install theos on your system (make sure to download the swift stuff too), add it to your path, and then just clone the repo and run ipabuild.sh. The ipa will be in /dist. If you're on windows, the steps are the same but you have to build/package the ipa manually.

This project is in very active development, heres a list of some current features:

- ability to run minecraft servers (duh)
- java version selector, as well as custom launch arguments
- memory allocation slider
- easy to use server setup
- a file manager that allows you to manage multiple servers
- easy server console interaction (via RCON)

In the future, I plan to add the following:

- better jailbroken/trollstore device support (allow the JVM to run in a seperate process)
- easy port forwarding (via UPNP and/or something like playit.gg)
- improved launch UI
- a GUI to configure all server and mod configs
- more system info in settings
- and probably much more but this is all I could think of for now

There are some limitations that I'm currently running into for jailed iOS, that I'm not sure are solvable. The main one is that the JVM must run in the same process as the app itself. Because of this, when the JVM is killed in any way, the app is also killed. So, at least for now, if you stop a server or create a forge/neoforge server in the server setup, the app will crash after the java process ends. You will not lose any data from a crash occuring this way, and in fact iOS doesn't even log it as a crash (you won't find an ips file for it in settings). This is solvable by running the JVM in a seperate process, however that is only possible on jailbroken/trollstore devices. (note: this functionality is not yet supported)

I'm open to feedback and suggestions for features, so you can contact me in the discord server. This app is still in beta, so expect a lot of bugs! Have fun running Minecraft servers on your phone!