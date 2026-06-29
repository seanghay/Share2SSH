<div align="center">
	<img src="assets/icon.png" width="128" height="128" alt="Share2SSH icon">
	<h1>Share2SSH</h1>
	<p>
		<b>Send files from your Mac to remote Linux servers over SSH — by drag &amp; drop or the Finder Share menu.</b>
	</p>
	<p>
		<a href="https://github.com/seanghay/Share2SSH/releases/latest"><img src="https://img.shields.io/github/v/release/seanghay/Share2SSH?label=download&style=flat-square" alt="Latest release"></a>
		<img src="https://img.shields.io/badge/platform-macOS-blue?style=flat-square" alt="Platform: macOS">
		<img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License: MIT">
	</p>
	<br>
</div>

Share2SSH is a small, native macOS app for pushing files to the servers you already have in `~/.ssh/config`. Drop a file on the window, or right‑click it in Finder → **Share → Share2SSH**, pick a server, and it's on its way over SFTP. It reads your real SSH config and keys — no new credentials to manage.

## Highlights

- **Drag & drop** files onto any server to upload them instantly.
- **Finder Share extension** — right‑click → Share → Share2SSH from anywhere in Finder.
- **Uses your real `~/.ssh/config`** — add, edit, and delete `Host` entries from the app; nothing proprietary.
- **Key-based auth** via your existing keys and ssh-agent. Passphrase-protected keys are supported (optionally remembered in the Keychain).
- **Two transfer modes** — *Copy* (always upload) and *Sync* (skip files already up to date on the server).
- **Remote file explorer** — browse the server, create/delete folders, upload into any directory, download files back, and set a folder as your upload destination.
- **Trust on first use** host‑key verification backed by `~/.ssh/known_hosts`.
- **Sandboxed** — access to `~/.ssh` is granted once via a standard macOS permission prompt.

## Install

1. Download the latest `Share2SSH.dmg` from the [Releases](https://github.com/seanghay/Share2SSH/releases) page.
2. Open the DMG and drag **Share2SSH** to your Applications folder.
3. On first launch, grant access to your `~/.ssh` folder when prompted.

> [!NOTE]
> Release builds are currently **unsigned**. The first time you open the app, right‑click it and choose **Open** to bypass Gatekeeper.

## Usage

1. **Grant access** to `~/.ssh` on first launch.
2. **Pick or add a server.** Existing `Host` entries from your SSH config appear automatically; use **+** to add a new one.
3. **Send files:**
   - Drag files onto the drop zone, or click **Choose Files…**, or
   - In Finder, right‑click a file → **Share → Share2SSH**.
4. **Choose a destination** by typing a remote path, or open **Browse Files** to pick one visually.

## How it works

Share2SSH is a pure‑Swift SFTP client built on [Citadel](https://github.com/orlandos-nl/Citadel) (which wraps SwiftNIO SSH), so it needs no external binaries and runs inside the macOS App Sandbox. The main app owns access to `~/.ssh` and performs every transfer; the Finder Share extension simply stages the selected files into a shared App Group container and hands the job to the app.

## Build from source

Requirements: macOS with Xcode 26 or later.

```sh
git clone https://github.com/seanghay/Share2SSH.git
cd Share2SSH
xcodebuild -project Share2SSH.xcodeproj -scheme Share2SSH -configuration Release build
```

Or just open `Share2SSH.xcodeproj` in Xcode and press **Run**. Swift Package dependencies resolve automatically.

## Limitations

- **Sync** mode skips files whose remote size and modification time match — it is not an rsync‑style delta transfer.
- **Key-based auth only.** Password authentication is not supported.
- ssh-agent may be unreachable inside the sandbox; private key files are the supported path.

## License

MIT © [Seanghay Yath](https://github.com/seanghay)
