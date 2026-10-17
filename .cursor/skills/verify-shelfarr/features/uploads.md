# Uploads

Upload Book accepts the formats listed on the form. Choosing or dropping a folder keeps supported book files, including nested audio files, and skips unsupported files. A request upload accepts one file and checks that its type matches the request.

## Sub-features

- `formats`: the file chooser and the displayed format list agree.
- `folder`: a mixed folder retains supported audio and skips notes or images.
- `request`: a request upload shows its context and does not offer a folder chooser.

## How to get to it (user POV)

After signing in as the seeded admin, open Admin, Manual Uploads, then Upload File.
Regular users use Uploads, then Upload File, when user uploads are enabled.
An open request offers Upload File when the current user can fulfill it.

## Driving it with the browser

Preconditions: use the isolated app and signed-in browser from `../SKILL.md`.
Keep background workers stopped so test uploads cannot start external lookups.

```bash
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" click --state "$STATE" --role link --name "Admin"
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Admin Dashboard"
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" click --state "$STATE" --role link --name "Manual Uploads"
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" click --state "$STATE" --role link --name "Upload File"
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" wait --state "$STATE" --text "Upload Book"
ruby "$WT/.cursor/skills/verify-shelfarr/drive.rb" shot --state "$STATE" --path "$EVIDENCE/upload-form.png"
```

Using the browser's file chooser, select a disposable folder containing an M4B,
an uppercase `.FLAC`, and a `.txt` file. The selection should report two supported
files. A folder containing only the text file should report no supported book
files. Capture both states before submitting anything. Check a narrow viewport
for wrapping and horizontal overflow, then restore the desktop viewport.

`test/system/upload_formats_test.rb` exercises the mixed-folder submission in a
real browser with synthetic files and the test job adapter. Its injected change
event does not replace a check of the operating system's folder chooser.

## Gotchas

- Folder uploads are available only on the bulk form, not the request form.
- A request's file type is checked by the server even when the chooser permits it.
- Queued uploads do not prove that import or audio validation succeeded.
- Screenshots reached through the real sign-in form remain the UI evidence;
  automated system-test sign-in is only regression coverage.
