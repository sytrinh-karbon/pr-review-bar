# PR Review Bar

A macOS menu bar app that shows the GitHub pull requests waiting for your review, and keeps your local clones up to date. It runs as one app, so it checks GitHub once per interval, no matter how many Claude sessions or terminals you have open.

## Install

The app needs macOS 14 or later. You build it on your own Mac from this repository.

1. Install the Xcode Command Line Tools, which compile the app. Skip this step if `xcode-select -p` already prints a folder.

   ```bash
   xcode-select --install
   ```

2. Install the GitHub CLI (`gh`) with [Homebrew](https://brew.sh), then sign in. The app reads your GitHub token from `gh auth token` and keeps it in memory only.

   ```bash
   brew install gh
   ```

   ```bash
   gh auth login
   ```

3. Download this repository, then build the app from its folder. The script creates `build/PR Review Bar.app`.

   ```bash
   ./scripts/build-app.sh
   ```

4. Move the app to Applications and open it.

   ```bash
   mv "build/PR Review Bar.app" /Applications/ && open "/Applications/PR Review Bar.app"
   ```

5. Click the app's icon in the menu bar, then click "Settings…". Pick your teams and repositories, and turn on Open at login. Allow notifications when macOS asks.

To update to a newer version, download the latest code, run `./scripts/build-app.sh` again, then replace the app in Applications:

```bash
osascript -e 'quit app "PR Review Bar"'; rm -rf "/Applications/PR Review Bar.app"; mv "build/PR Review Bar.app" /Applications/ && open "/Applications/PR Review Bar.app"
```

## What it shows

The menu bar icon shows how many pull requests need your review. Click it to see four groups:

| Group | What is in it |
|---|---|
| Needs your review | Pull requests where it is your turn: you have not acted yet and nothing blocks them, the author pushed or replied after your last review or comment, or someone requested you by name. |
| Waiting on author | Pull requests where the author must act next: after your change request or comment, or after anyone's change request, with no push or reply from the author since. |
| Approved by you | Pull requests you approved that are still open. |
| Your pull requests | Your own open pull requests, with who approved and who asked for changes. |

Draft pull requests, merged or closed pull requests, and pull requests opened by bots are never shown.

Only the author can hand the turn back. Comments from other reviewers or bots do not move a pull request. Inside Needs your review, pull requests that others already approved come last, under "Already approved by others", unless you were requested by name or the author responded to you.

The menu bar count leaves out pull requests that others already approved. The person button in the menu header shows only pull requests involving you: requested from you, or reviewed or commented on by you.

Sort with the arrows button in the menu header:

| Sort | Order |
|---|---|
| Most urgent | Requested from you, then ones where the author responded to you, then the oldest |
| Latest comment | Newest comment from a reviewer first |
| Recently updated | Newest update first |
| Newest opened | Most recently created first |
| Oldest opened | Longest waiting first |

Each card has a colored stripe on its left edge for its review status: green when approved, orange when approved but more approvals are needed, red when someone asked for changes, and gray when not approved yet. "Approved" follows the repository's required number of approvals; a repository without that rule needs one. A blue badge says how you are involved: "Requested from you", "Author responded to you", "You commented", "You requested changes", "You approved", or "Changed since you approved". CI status is a separate icon, labeled "CI".

The comment count includes only reviewers: people other than the author, not bots. The text of a review counts as one comment. "· 2 new" in blue means 2 of them came after your last action. Hover over the count to see who commented.

- Click a card to open the pull request in your browser.
- Hover over a card and click the cross to hide it. Right-click a card for the same option. Restore hidden pull requests in Settings › Hidden.

## Settings

| Setting | Choices |
|---|---|
| Teams and repositories | Pick one or more of your GitHub teams, then tick the repositories to watch. |
| Check for updates | Every 2, 5, 10, 15, 30 or 60 minutes. A manual refresh button is in the menu. The app also refreshes when your Mac wakes up. |
| Skip idle pull requests | Hide pull requests with no activity for more than 7, 14, 30, 60 or 90 days, or never hide them. |
| Already approved by others | Move them to the bottom of Needs your review, or hide them. |
| Branch filter | Show only pull requests whose branch name contains this text, such as `payments`. Leave it empty for all branches. Your own pull requests are always shown. |
| Also treat these accounts as bots | GitHub usernames, separated by commas, for bots that run as normal accounts, such as `deploy-bot`. Their pull requests, reviews and comments are left out. |
| Opened by members of | Tick teams, such as `team-payments`, to show only pull requests their members opened. Tick none to show everyone's. Your own pull requests are always shown. |
| Show on each card | Any of: review status, comment count from reviewers, CI status, waiting time (when it was opened and last updated), and size (lines added in green and removed in red, as on GitHub). |
| Notifications | A new review or comment on your pull requests, and "It's my turn again": the author pushed or replied after your review or comment. Click a notification to open the pull request. |
| Open at login | Starts the app when you log in. |

## Keeping local repositories up to date

In Settings › Local Repos, choose the folder that holds your clones (for example `~/Code`). The app finds every git clone directly inside it and shows the GitHub repository each one points to. Untick a clone to leave it out.

Every 5, 10, 15, 30 or 60 minutes, separately from the pull request check, the app fetches all clones in parallel, six at a time. For each clone it then updates the default branch (`main` or `master`) like this:

| Your clone is | What happens |
|---|---|
| On `main` | `main` is fast-forwarded to `origin/main`. Uncommitted changes stay. If they touch files the update changes, the clone is left as is. |
| On another branch | Your branch and files are not touched. `main` is moved forward to `origin/main`, so it is current when you switch to it. |
| On a `main` with local commits not on origin | `main` is left as is. |
| Has `main` checked out in another worktree | `main` is left as is. |

Anything left as is shows in orange in the settings, and the menu shows how many clones need attention. Linked worktrees are not listed, because they share their main clone's branches.

## Run the tests

```bash
swift test
```

With only the Command Line Tools installed (no Xcode), building the tests sometimes fails with `plugin for module 'TestingMacros' not found`. Run the command again; it passes on a later try.
