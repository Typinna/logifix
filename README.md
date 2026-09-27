# logifix

`logifix` is a workaround patch for a longstanding Logi Options+ limitation on macOS where plugin functionality does not reliably follow the active user when multiple macOS accounts remain logged in through Fast User Switching.

Instead of requiring one user to fully log out before another user can use Logi Options+ plugins, `logifix` detects when the active macOS console user changes and performs a controlled handoff of the Logi Options+ plugin environment to the newly active user.

With this patch, multiple macOS user accounts can remain logged in, and the LogiPluginService will function as it is supposed to.

---

## Disclaimer

> **Use this at your own risk.**
>
> `logifix` is an unofficial community workaround and is not affiliated with, supported by, or endorsed by Logitech or Apple.
>
> The utility runs a LaunchDaemon as root, stops selected Logitech processes, unloads and reloads Logitech's existing LaunchAgent, and removes a small number of specifically named Logitech IPC socket files from `/private/tmp`.
>
> The scripts are intentionally narrow in scope, but they still operate with elevated privileges and modify runtime state belonging to third-party software.
>
> Review the source before installing it.
>
> Future versions of macOS, Logi Options+, or LogiPluginService may change process names, paths, launchd behavior, or IPC architecture and could make this workaround unnecessary, incompatible, or unsafe.

---

## Reporting issues

I do not intend to maintain or update this patch going forward. I created this repo and am sharing it for two reasons, in priority order:

1. Out of spite for Logitech.

Apple explicitly warns macOS developers that Fast User Switching leaves multiple user sessions alive at once, and recommends session-specific names for resources in global locations like `/tmp` to avoid collisions.

Logitech, meanwhile, uses a globally named socket with no user or session identifier:

```text
/private/tmp/LogiPluginService
```

That is exactly the kind of design Apple tells developers to avoid for Fast User Switching. The platform guidance exists, the failure mode is predictable, users have been complaining for years, yet Logitech still relies on a shared global IPC resource that breaks clean multi-user handoff.

2. Because there was no good information on this topic online when I first discovered the issue, and I want to share this as a resource for anyone seeking answers. Should this patch break, hopefully this points you in the right direction.


---

## Tested environment

This workaround was originally developed and tested on:

- **Hardware:** MacBook Pro M1 Pro
- **Architecture:** Apple Silicon / arm64
- **macOS:** Tahoe 26.6.2
- **Logi Options+:** 2.8.981479
- **Simultaneously logged-in accounts tested:** 2

---

## The problem

The issue appears when multiple macOS users remain logged in at the same time.

A typical sequence looks like this:

```text
User A logs in
        ↓
Logi Options+ initializes for User A
        ↓
User A remains logged in
        ↓
Fast User Switch to User B
        ↓
User B becomes the active macOS user
        ↓
Logi Options+ plugin functionality does not
reliably transfer to User B
```

The Logitech device itself continues working as a normal mouse or keyboard.

The issue is specifically with the Logi Options+ environment and LogiPluginService-dependent functionality like the Actions Ring, Mouse Gestures, customized buttons, etc.

Since Logitech has failed to fix this issue for its macOS users after years of users speaking about it online, the only reliable way to use these functionalities across multiple Mac user accounts that remained logged in at the same time was:

```text
Log out User A completely
        ↓
Log into User B
```

That defeats much of the purpose of Fast User Switching and provides a horrible user experience.

`logifix` instead allows:

```text
User A remains logged in
        ↓
Fast User Switch to User B
        ↓
logifix hands the Logitech plugin environment to User B
```

and performs the same process in reverse when switching back.

---

## How the solution was discovered

I purchased the MX Master 4 as an upgrade from my MX Anywhere 3S, eager to take advantage of the Actions Ring functionality and deeper customization it provided.

After receiving it and spending ~2 hours customizing it in Logi Options+ on both of my Mac user accounts, I was extremely frustrated when the Actions Ring and mouse gestures simply would not work on one of my two user profiles.

I learned that other users have been reporting the same issue for years with no official fix from Logitech. I also found the only solution was to log out of all other user profiles before logging into the profile where Logi Options would be used. I considered returning the MX Master 4 out of spite for the fact that Logitech seems to have ignored this complaint for so long.

In the end, I just suffered through it and continued logging out before switching accounts. After a couple of months of this, I mistakenly discovered why this issue even exists, and found a persistent solution for it while troubleshooting what I thought was a totally unrelated error. Details on that error and the subsequent discovery which lead to logifix are below.

A LogiPluginService failure occurred where Logi Options+ became stuck displaying:

```text
Please wait while Logi Plugin Service is being restarted
```

I began troubleshooting. While the exact cause was never conclusively established, I was able to fix it. In fixing it, I was able to solve the Logi Options fast user switching problem.

Context: Logi Options+ is on my list of Login Items. Once I log into any user account, Logi Options+ initializes. Leading up to the LogiPluginService failure I was trying to log out of USER A and log into USER B. I accidentally logged back into USER A. I immediately realized it was the wrong user and hit logged out again.

My current theory is that the immediate logout after Logi Options+ began initializing interrupted its normal startup/shutdown process, and it did not have enough time to cleanly shut down its IPC resources before the session ended and the user was logged out.

That remains a hypothesis.

What happened next, however, was directly observable.

---

## The `bind: Address already in use` finding

The failure chain was effectively:

```text
stale /private/tmp/LogiPluginService socket
→ bind() fails with EADDRINUSE
→ uncaught std::system_error
→ SIGABRT
→ Logi Options+ restarts service
→ same stale socket still exists
→ infinite restart loop
```

During this PluginService failure, crash reports showed LogiPluginService terminating while creating a local IPC server. Specifically, I found:

```text
std::__1::system_error: bind: Address already in use
```

Naturally, I thought I'd try finding and terminating whatever was using this resource that LogiPluginService needed.

The crash report's stack specifically showed:
```text
asio::local::stream_protocol
```

This points to a Unix-domain socket/local endpoint. 

Next step was to identify the exact Unix socket name/path it is trying to bind. What I found were a few relevant Unix-domain socket filesystem entries:

```text
/private/tmp/LogiPluginService
/private/tmp/LogiPluginServiceControlBus_USER_A
/private/tmp/LogiPluginServiceControlBus_USER_B
```

None of these appeared in the list of sockets currently owned by running processes. How was an address already in use if no running process owned them?

What I knew was that the socket bind was failing with EADDRINUSE even though no process is actually listening on it.

I decided to just remove the unowned stale sockets and get back to work. After attempting this, two still survived, both belonging to USER A. I was signed into USER B, so, I was even more confused.

At this point I started thinking that maybe when I previously logged into USER A and immediately logged out while Logi Options was a login item, it was possible I interrupted Logi Options startup/shutdown process causing a stuck, stale socket, which is now preventing USER B from binding.

I logged out of USER B and back into USER A, and found that LogiPluginService was still working normally on USER A.

I then logged out of USER A and back into USER B, and was still getting 'Please wait while Logi Plugin Service is being restarted'.

This suggested that USER A's active session was capable of recreating/using its own IPC state correctly, while USER B's session was colliding with the global socket: `/private/tmp/LogiPluginService`

So I decided I would remove the two confirmed-unowned stale sockets and restart Logi Options.

```text
sudo rm -v \
  /private/tmp/LogiPluginService \
  /private/tmp/LogiPluginServiceControlBus_USER_A
```

Success!

---

## What was confirmed

- LogiPluginService uses unix-domain IPC.
- A global socket exists at:

```text
/private/tmp/LogiPluginService
```

- User-specific ControlBus sockets exist at:

```text
/private/tmp/LogiPluginServiceControlBus_<username>
```

- One LogiPluginService crash produced:

```text
bind: Address already in use
```

- The crash stack showed a local socket `bind()` operation.
- Stopping the plugin process family and cleaning the known IPC resource allowed PluginService to initialize normally.


The most important finding was the ControlBus socket names are user-specific:
```text
LogiPluginServiceControlBus_userA
LogiPluginServiceControlBus_userB
```
But the primary socket is not. It is a globally named IPC resource:
```text
/private/tmp/LogiPluginService
```

So I thought I would see if stopping the existing Logitech plugin environment on user switch and starting it for the newly active user might solve the Fast User Switching dilemma without logging out.

Turns out it worked. Thus, logifix was born.

---

## What logifix does

`logifix` does not attempt to make multiple LogiPluginService environments run simultaneously.

It hands the Logitech plugin environment to whichever configured macOS user currently owns the console.

When the active user changes:

```text
User A is active
        ↓
Fast User Switch
        ↓
User B becomes active
        ↓
logifix detects the console-user change
        ↓
Logitech LaunchAgent supervision is stopped
        ↓
LogiPluginService components are stopped
        ↓
known Logitech IPC sockets are cleaned
        ↓
Logi Options+ starts for User B
        ↓
PluginService initializes for User B
```

Both users remain logged in throughout the process.

---

## Design

`logifix` deliberately uses explicit paths and an explicit user allowlist.

It does **not**:

- delete Logi Options+ databases
- delete Logitech device profiles
- delete arbitrary files from `/private/tmp`
- wildcard-delete temporary files
- modify Keychain contents
- modify Bluetooth pairing information
- patch Logitech binaries
- disable macOS security mechanisms
- kill every process containing the word `Logitech`
- remove the Logi Options+ updater
- attempt to run multiple PluginService environments simultaneously

---

## Components managed by logifix

### Logitech LaunchAgent

`logifix` stops Logitech's existing LaunchAgent for configured users and restarts it for the newly active foreground user:

```text
com.logi.cp-dev-mgr
```

located at:

```text
/Library/LaunchAgents/com.logi.optionsplus.plist
```



### LogiPluginService

`logifix` targets processes running from:

```text
/Applications/Utilities/LogiPluginService.app/Contents/
```

Observed processes include:

```text
LogiPluginService
LogiPluginServiceNative
LogiPluginServiceExt
```

The service is first asked to terminate normally.

If it fails to exit within a short grace period, `SIGKILL` is used as a fallback.

### IPC sockets

`logifix` only removes:

```text
/private/tmp/LogiPluginService
```

and:

```text
/private/tmp/LogiPluginServiceControlBus_<configured-user>
```

It does not wildcard-delete `/private/tmp`.

Before removing the shared socket, `logifix` verifies that no LogiPluginService process remains running.

If an unexpected PluginService process remains, the handoff aborts instead of deleting the socket.

---

## Project layout

```text
logifix/
├── README.md
├── install-logifix.sh
├── uninstall-logifix.sh
├── logifix-handoff.sh
├── logifix-watcher.sh
└── com.local.logifix.plist
```

Installed files:

```text
/Library/Application Support/LogiFix/
├── users.conf
├── logifix-handoff.sh
└── logifix-watcher.sh
```

LaunchDaemon:

```text
/Library/LaunchDaemons/com.local.logifix.plist
```

---

## Installation

Clone or download this repository.

Then make the scripts executable:

```bash
chmod +x \
install-logifix.sh \
uninstall-logifix.sh \
logifix-handoff.sh \
logifix-watcher.sh
```

Install:

```bash
sudo ./install-logifix.sh
```

The installer will:

1. verify that it is running as root
2. validate the included scripts
3. validate the LaunchDaemon plist
4. confirm that Logi Options+ is installed
5. discover local interactive macOS users
6. ask which users should participate
7. validate the selected accounts
8. require at least two configured users
9. install `logifix`
10. create `users.conf`
11. install the LaunchDaemon
12. start the watcher
13. verify that the watcher is registered with `launchd`

You can also supply usernames directly:

```bash
sudo ./install-logifix.sh alice bob
```

For more than two accounts:

```bash
sudo ./install-logifix.sh alice bob work
```

---

## Configuration

Managed users are stored in:

```text
/Library/Application Support/LogiFix/users.conf
```

Example:

```text
alice
bob
work
```

One macOS short username is used per line.

Comments and blank lines are allowed:

```text
# Personal account
alice

# Work accounts
bob
work
```

The watcher reloads this configuration while running.

---

## Find your macOS short username

Run:

```bash
id -un
```

To list local users and UIDs:

```bash
dscl . -list /Users UniqueID
```

---

## Normal use

After installation, there is nothing to run manually.

Use Fast User Switching normally.

Example:

```text
alice active
        ↓
Fast User Switch
        ↓
bob active
        ↓
logifix detects the change
        ↓
Logitech plugin environment is handed to bob
```

The same process occurs when switching back.

---

## Startup behavior

`logifix` installs:

```text
/Library/LaunchDaemons/com.local.logifix.plist
```

with:

```xml
<key>RunAtLoad</key>
<true/>

<key>KeepAlive</key>
<true/>
```

This means the watcher starts automatically when macOS boots.

On the first configured user session observed after startup, `logifix` records that user as the baseline and does not unnecessarily restart Logitech.

A handoff happens when the foreground console user later changes to another configured account.

---

## Expected handoff time

Logi Options+ and PluginService do not always initialize immediately.

During testing, one observed transition took approximately:

```text
~10 seconds
Options+ exits/restarts

~20 additional seconds
Bluetooth devices are recognized again

~15 additional seconds
PluginService becomes available
```

Approximately 45 seconds total was observed in that case.

`logifix` therefore allows PluginService up to:

```text
60 seconds
```

to initialize.

The readiness check exits early if PluginService becomes available sooner.

---

## Logs

### Handoff log

```text
/var/log/logifix-handoff.log
```

### Watcher log

```text
/var/log/logifix-watcher.log
```

### LaunchDaemon stdout

```text
/var/log/logifix-launchd.log
```

### LaunchDaemon stderr

```text
/var/log/logifix-launchd-error.log
```

To watch activity live:

```bash
sudo tail -f \
/var/log/logifix-watcher.log \
/var/log/logifix-handoff.log
```

---

## Check logifix status

```bash
sudo launchctl print system/com.local.logifix
```

A healthy installation should report:

```text
state = running
```

Compact version:

```bash
sudo launchctl print system/com.local.logifix |
grep -E 'state =|pid =|program =|last exit code'
```

---

## Check the current console user

```bash
stat -f '%Su' /dev/console
```

---

## Check Logitech processes

```bash
pgrep -alf \
'logioptionsplus_agent|LogiPluginService'
```

A functioning foreground session may include:

```text
logioptionsplus_agent --launchd
LogiPluginService
LogiPluginServiceNative
LogiPluginServiceExt
```

---

## Check Logitech IPC sockets

```bash
find /private/tmp \
-maxdepth 1 \
-type s \
\( -name 'LogiPluginService' \
   -o -name 'LogiPluginServiceControlBus_*' \) \
-print
```

A functioning active session may show:

```text
/private/tmp/LogiPluginService
/private/tmp/LogiPluginServiceControlBus_<current-user>
```

---

## Why not just delete `/private/tmp/LogiPluginService`?

Because removing a Unix-domain socket while its service is still active is not a safe general recovery strategy.

`logifix` follows this sequence:

```text
stop LaunchAgent supervision
        ↓
stop PluginService processes
        ↓
verify PluginService is gone
        ↓
remove only known IPC sockets
        ↓
start the active user's LaunchAgent
```

If an unexpected PluginService remains active, `logifix` refuses to remove the shared socket.

---

## Add or remove a managed user

Edit:

```bash
sudo nano \
"/Library/Application Support/LogiFix/users.conf"
```

Example:

```text
alice
bob
charlie
```

The watcher reloads the configuration automatically.

---

## Updating logifix

Download the newer release and run:

```bash
sudo ./install-logifix.sh
```

If `logifix` is already installed and no usernames are supplied, the installer preserves the existing valid `users.conf`.

To intentionally replace the configured user list:

```bash
sudo ./install-logifix.sh alice bob
```

---

## Uninstall

Run:

```bash
sudo ./uninstall-logifix.sh
```

This removes:

- the LogiFix LaunchDaemon
- `/Library/Application Support/LogiFix`
- LogiFix runtime state
- LogiFix logs

It does **not** uninstall Logi Options+.

It does **not** remove Logitech settings, device profiles, databases, Bluetooth pairings, or Keychain data.

To uninstall but keep diagnostic logs:

```bash
sudo ./uninstall-logifix.sh --keep-logs
```

---

## Known limitations

`logifix` has currently been tested on a limited configuration.

It has not yet been extensively validated on:

- Intel Macs
- all Apple Silicon generations
- all supported macOS versions
- all Logi Options+ versions
- more than two simultaneously logged-in users
- every Logitech device
- enterprise-managed Macs with customized security or launchd policies

Logitech may change:

- process names
- application paths
- LaunchAgent identifiers
- IPC architecture
- PluginService startup behavior

Apple may also change Fast User Switching or launchd behavior.

A future Logi Options+ update may fix the underlying limitation entirely.

---

## License

This project is licensed under the MIT License.

---

## Summary

I paid $160 for this mouse, Logitech. Do better.
