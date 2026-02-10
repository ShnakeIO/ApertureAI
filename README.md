# ApertureAI (macOS AI Chat + Google Drive Agent)

ApertureAI is a macOS desktop chat app built with C++/Objective-C++ and Cocoa.
It uses a warm orange/white interface, connects to OpenAI for responses, and can browse/read Google Drive files via tool-calling.
It can extract text from:
- Google Docs / Sheets (export)
- Plain text/code files
- PDF files (PDFKit extraction)
- DOCX files (DOCX XML extraction)

Drive responses include file IDs and `webViewLink` URLs so answers can cite the exact source file link.

## OpenAI setup

Preferred for this app: put your key in:

`src/apertureai.env`

Example:

```bash
OPENAI_API_KEY=YOUR_KEY_HERE
OPENAI_MODEL=gpt-4o-mini
```

You can still use environment variables instead:

```bash
export OPENAI_API_KEY="YOUR_KEY_HERE"
```

Optional overrides:

```bash
export OPENAI_MODEL="gpt-4o-mini"
export OPENAI_PROJECT="proj_..."
export OPENAI_ORGANIZATION="org_..."
```

## Google Drive setup

1. Enable the Google Drive API in your Google Cloud project.
2. Create a service account key JSON and place it in `src/` (example: `src/my-service-account.json`).
3. Share the target Google Drive folder with the service account email (`...@...iam.gserviceaccount.com`) as Viewer.
4. Set these values in `src/apertureai.env`:

```bash
GOOGLE_DRIVE_FOLDER_ID=YOUR_FOLDER_ID
GOOGLE_SERVICE_ACCOUNT_FILE=src/my-service-account.json
```

Folder ID example:
`https://drive.google.com/drive/folders/<FOLDER_ID>`

## OneDrive / SharePoint setup (optional)

1. In Azure Portal, register an app in Microsoft Entra ID.
2. Create a client secret for that app.
3. Add Microsoft Graph application permissions:
`Files.Read.All` and `Sites.Read.All` (or `Sites.Selected` if you want scoped site access).
4. Grant admin consent for the tenant.
5. Put these values in `src/apertureai.env`:

```bash
MICROSOFT_TENANT_ID=YOUR_TENANT_ID
MICROSOFT_CLIENT_ID=YOUR_APP_CLIENT_ID
MICROSOFT_CLIENT_SECRET=YOUR_APP_CLIENT_SECRET
```

Optional default target (set one):

```bash
MICROSOFT_DRIVE_ID=YOUR_DRIVE_ID
# or
MICROSOFT_SITE_ID=YOUR_SHAREPOINT_SITE_ID
# or
MICROSOFT_USER_ID=user@your-company.com
```

## Auto-update setup (GitHub Releases)

The Electron app is configured to publish/read updates from:
`ShnakeIO/ApertureAI`

What is already configured:
- `electron/electron-builder.yml` has GitHub publish settings.
- The app now checks for updates every 5 seconds while open.
- When an update exists, a top banner shows a clear update message and button.

Important for this repo:
- `ShnakeIO/ApertureAI` is private, so installed apps need a GitHub token at runtime.
- Do not edit the signed app bundle to add token values.
- Add this in the user config file:
`~/Library/Application Support/ApertureAI/apertureai.env`

```bash
GITHUB_TOKEN=YOUR_GITHUB_TOKEN
```

If macOS updater shows:
`code failed to satisfy specified code requirement(s)`
install the latest release manually once, then in-app updates work from that point forward.

To publish updates:

1. Bump version in `electron/package.json` (for example `1.0.0` -> `1.0.1`).
2. Create a GitHub token that can write releases for this repo.
3. Set token in your shell:

```bash
export GH_TOKEN=YOUR_GITHUB_TOKEN
```

4. Build and publish from `electron/`:

```bash
npm ci
npm run release
```

This uploads release artifacts and update metadata used by `electron-updater`.

Automatic publishing is also set up in:
`/.github/workflows/electron-release.yml`

Push a version tag like `v1.0.1` to trigger GitHub Actions publish.

## Build

```bash
cmake -S . -B build
cmake --build build
```

## Run

```bash
open build/ApertureAI.app
```

If `open build/ApertureAI.app` does not start correctly, run the binary directly:

```bash
./build/ApertureAI.app/Contents/MacOS/ApertureAI
```
