# envvars-mac

A tiny native Mac app for adding environment variables and copying them back out. Type a name and a value, press Return, done. Each saved variable has buttons to copy its **name**, its **value**, a ready-to-paste **`export NAME="value"`** line, or a **ready-made message** you can hand to an AI coding agent.

It's SwiftUI, around 1,200 lines, no dependencies, and no network access. macOS 13 (Ventura) or newer, Intel and Apple Silicon.

## Why does this exist

If, like me, you deal with an unreasonable number of SPNs (service principals), secrets and environment variables on your machine every single day, you'll know the small, constant friction of getting each one into the right place. For me that was costing about 4.5 minutes a time. I built this because, well, why not. Four and a half minutes is a lot of sleep I could have been getting.

## Quick start

You need the Xcode Command Line Tools (not full Xcode). Install them once:

```sh
xcode-select --install
```

Then:

```sh
git clone https://github.com/YasserMickey/envvars-mac.git
cd envvars-mac
./build.sh
open EnvVars.app
```

You can also drag `EnvVars.app` into your Applications folder.

The build is **ad-hoc signed**, not notarised, so on first launch macOS may refuse to open it. If that happens, right-click the app, choose **Open**, then **Open** again. You only need to do this once.

`build.sh` makes a universal binary (Apple Silicon and Intel). If that fails, it falls back to building for the Mac you're on.

## How it stores data

- Variables live in `~/.envvars/env.zsh` as plain `export NAME='value'` lines. The folder is `chmod 700` and the file is `chmod 600`.
- The app re-reads the file on launch, whenever it comes to the front, and before every change, so it's fine to edit the file by hand too. Lines it doesn't understand are left alone.
- **"Load in new Terminal windows"** is a switch at the bottom of the window, and it's **off by default**. When you turn it on, the app asks first, copies `~/.zshrc` to `~/.zshrc.envvars-backup` (only once), and adds this block:

  ```sh
  # >>> EnvVars app >>>
  [ -f ~/.envvars/env.zsh ] && source ~/.envvars/env.zsh
  # <<< EnvVars app <<<
  ```

  Turning the switch off removes exactly that block and nothing else.
- Terminal windows that are already open won't see changes until you run `source ~/.envvars/env.zsh`.

## The copy buttons

| Button | What lands on your clipboard |
| --- | --- |
| **Name** | `MY_API_KEY` |
| **Value** | the value, exactly as saved |
| **Export** | `export MY_API_KEY="the value"` (quoted safely; values with `!` or line breaks use single quotes) |
| **Message** | your message template with the name filled in (see below) |
| **Copy all as export lines** | every variable as an `export` line, one per line |

Values are hidden by default; the eye icon reveals one. Double-click a row to edit it.

## Customise the message

The **Message** button copies a sentence you can paste straight into Claude, Codex or whatever agent you use, to tell it about a variable you just added. Out of the box it says:

> Hi, I've added a new environment variable that is called MY_API_KEY. Please follow the workflow that's associated with that.

That's only the default. **You can change it to say whatever you like.** Three ways:

1. **In the app:** click **Edit message…** (next to "Copy all as export lines"). You get a text box, a live preview, **Reset to default**, **Save** and **Cancel**.
2. **By hand:** edit `~/.envvars/message.txt`. It's a plain text file, and the app reads it on every copy, so changes apply straight away. Delete the file (or leave it empty) to go back to the default.
3. **In the source:** it's open source, so fork it. The built-in default lives in [`Sources/EnvStore.swift`](Sources/EnvStore.swift) as `MessageTemplate.defaultTemplate`.

Write `{{NAME}}` wherever you want the variable's name to appear. You can use it more than once, or not at all, and the message can span several lines. The placeholder is exact and case-sensitive.

Example template:

```text
I've added an environment variable called {{NAME}}.
Follow the "new-env-var" workflow for {{NAME}}. Never print its value.
```

## Pair it with your agent instructions

A message is much more useful when the agent already knows what to do with it. You can couple your custom message with instructions in your `AGENTS.md` (Codex) or `CLAUDE.md` (Claude Code) file that apply a specific workflow once that message arrives in your harness. The message is the trigger, and the instructions file is the workflow.

For example, with the default message, something like this in your `CLAUDE.md` or `AGENTS.md`:

```markdown
## New environment variables

When I say I've added a new environment variable called <NAME>:

1. Read it from the shell environment (`printenv <NAME>`) to check that it exists.
   If it's missing, tell me to run `source ~/.envvars/env.zsh` and stop.
2. Never print, log or echo its value, and never write it into a file in this repo.
3. Add <NAME> (name only) to `.env.example` and to the "Configuration" section of the README.
4. Reference it in code as `process.env.<NAME>` / `os.environ["<NAME>"]`, never as a literal.
5. Tell me what you changed, mentioning the name only.
```

Change the steps to match your own setup: store it wherever your secrets go, update whatever should know about it, and so on. If you change the message text, change the matching line in your instructions file too, so the agent still recognises the trigger.

## Security note

Values are stored **in plain text** in a file that only your user can read (`chmod 600`). They are **not** in the Keychain. That's the same level of protection as any other dotfile. Don't put anything in here that you wouldn't be comfortable keeping in a dotfile, and remember that anything you copy sits on the clipboard until you copy something else. The app doesn't talk to the network. Read the code if you'd like to check; it's short.

## Development

The logic that doesn't depend on the UI (parsing and writing `env.zsh`, quoting, the `~/.zshrc` block, the message template) is in `Sources/EnvStore.swift`, which only imports Foundation. It has tests that run on macOS or Linux:

```sh
bash Tests/run.sh
```

The SwiftUI parts are `EnvVarsApp.swift`, `ContentView.swift` and `EnvViewModel.swift`.

## Licence

[MIT](LICENSE) © Yasser Nabil. Do what you like with it, and if you improve it, a pull request is welcome.
