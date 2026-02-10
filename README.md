If you would like support, want to request a feature, or just talk to other JESSI users you should join the discord: https://discord.gg/aZ9HbYXKur

# Basic Information

JESSI is a jailed app that runs Minecraft: Java Edition servers natively on iOS, targeting iOS 14+. While JESSI can run on non jailbroken devices, it requires JIT to be enabled in order to actually function.

To enable JIT on iOS 14-17.0, just use trollstore to install JESSI, and JIT will automatically work.

To enable JIT on iOS 17.0.1-17.3.1, good luck!

To enable JIT on iOS 17.4-18.7.4, you must first install [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) and [StikDebug](https://github.com/StephenDev0/StikDebug). After this, you will need to get your pairing file. If you have [iloader](https://github.com/nab138/iloader) installed on a computer, you can place the pairing file into StikDebug with the "Manage Pairing File" button found in the 'Management' section on the left. Or if you have SideStore installed and don't want to use a computer, you can import the file from the app by clicking on the 'Inport Pairing File' button in StikDebug's settings. Click the 'Browse' button in the bottom. Click on "On My iPhone/iPad", then "SideStore", then on the file named "ALTPairingFile.mobiledevicepairing". Finally, enable the VPN in LocalDevVPN and you're ready to enable JIT. Make sure you have JESSI installed, then in StikDebug tap the "Connect by App" button and select JESSI. To make sure JIT is enabled, you can check the settings tab in JESSI.

To enable JIT on iOS 26+, first follow all of the steps for iOS 17.4-18.7.4. If you have an A13-A14/M1 device, you're done! if you have an A15+/M2+ device, then in StikDebug set the default script to Amethyst-MeloNX.js (or assign that script to JESSI), and then launch JESSI via StikDebug. if you did it correctly, it should open a PIP window with a bunch of logs. Then in settings, enable the "TXM Support" option.

**Note: Make sure to install a JVM in settings. If you don't know which version to select, select Java 21.**

# LiveContainer

JESSI also works inside of [LiveContainer](https://github.com/LiveContainer/LiveContainer). Make sure to launch the app with JIT. To do this, long press on JESSI after installing it in LiveContainer, then go into the settings of it, then toggle on Launch with JIT. JESSI should now always launch with JIT! (assuming you have LiveContainer set up with JIT properly).

# Features

This project is in very active development, heres a list of some current features:

- Ability to run minecraft servers (duh)
- Java version selector, as well as custom launch arguments
- Memory allocation slider
- Easy to use server setup
- A file manager that allows you to manage multiple servers
- Easy server console interaction (via RCON)
- Downloading only the JVM's you want
- Network tunneling via playit.gg and UPnP support
- Integrated mod downloading via Modrinth (curseforge etas0n)

In the future, I plan to add the following:

- Better jailbroken/trollstore device support (allow the JVM to run in a seperate process)
- Improved launch UI
- A GUI to configure all server and mod configs
- More system info in settings
- Modpack support
- And probably much more but this is all I could think of for now

# Building/Miscellaneous extra info

If you would like to build JESSI yourself, it's pretty simple. Install XCode and XCode CLI, then run scripts/build-ipa.sh

There are some limitations that I'm currently running into for jailed iOS, that I'm not sure are solvable. The main one is that the JVM must run in the same process as the app itself. Because of this, when the JVM is killed in any way, the app is also killed. So, at least for now, if you stop a server or create a forge/neoforge server in the server setup, the app will crash after the java process ends. You will not lose any data from a crash occuring this way, and in fact iOS doesn't even log it as a crash (you won't find an ips file for it in settings). This is solvable by running the JVM in a seperate process, however that is only possible on jailbroken/trollstore devices. (note: this functionality is not yet supported)

I'm open to feedback and suggestions for features, so you can contact me in the discord server. This app is still in beta, so expect a lot of bugs! Have fun running Minecraft servers on your phone!
