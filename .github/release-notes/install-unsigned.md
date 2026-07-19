## Install

Download the `.dmg`, open it, and drag Markive to Applications.

Markive is unsigned. macOS quarantines web downloads, and for an unsigned app that shows up as **"Markive is damaged and can't be opened"**. It isn't. Clear the flag once:

```bash
xattr -dr com.apple.quarantine /Applications/Markive.app
```

Then open it normally. For the `markive` command line tool: Settings (⌘,) → Install Command Line Tool.
