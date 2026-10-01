# Persistent Android signing and manual builds

## Why the signature changed

The previous workflow skipped signing configuration when secrets were missing. Gradle then used the runner's debug keystore, which is generated anew on each fresh runner. Android cannot install one of those APKs over an APK from another run.

Release builds now require a release keystore. Actions checks both the supplied keystore and every APK against the public certificate fingerprint in [.github/android-signing.sha256](../.github/android-signing.sha256). Missing secrets, incorrect passwords, or a different key fail the build before any APK is uploaded.

The persistent fork certificate is:

```
0D:90:B3:98:A2:BE:86:F4:C6:70:6D:81:FC:C6:F0:DB:
A4:12:9C:9B:4A:7C:CC:11:E6:4F:A4:99:53:43:B8:20
```

## Set up the existing fork key once

Keep the private signing backup outside the repository. It contains `piliplus-release.p12` and `release-signing.json`. Do not generate another key for each build.

Using Python 3, Java's `keytool`, and an authenticated [GitHub CLI](https://cli.github.com/) account with permission to manage this repository's Actions secrets, run from the repository root:

```sh
python3 .github/scripts/android_signing.py configure \
  --keystore /private/path/piliplus-release.p12 \
  --credentials /private/path/release-signing.json \
  --repo alvinmhng/PiliPlus
```

The script verifies the certificate and sets these four repository secrets through standard input, without printing their values:

| Actions secret | Backup field |
| --- | --- |
| `SIGN_KEYSTORE_BASE64` | Base64 encoding of `piliplus-release.p12` |
| `KEYSTORE_PASSWORD` | `storePassword` |
| `KEY_ALIAS` | `keyAlias` |
| `KEY_PASSWORD` | `keyPassword` |

The secrets are stored under [Settings → Secrets and variables → Actions](https://github.com/alvinmhng/PiliPlus/settings/secrets/actions). All future Android builds reuse them. Changing the signing certificate requires deliberate migration; it cannot upgrade existing APKs.

## Build and publish manually

Open [Actions → Build](https://github.com/alvinmhng/PiliPlus/actions/workflows/build.yml), choose `main`, and select the platforms to build. Leave `tag` empty for downloadable workflow artifacts, or provide a tag to use the existing manual release option. Android builds verify the fixed signature, then remove the temporary keystore and password file from the runner.

The application checks this fork's latest published stable release at `https://api.github.com/repos/alvinmhng/PiliPlus/releases/latest`. Downloads and source links also point to this fork. Build numbers prevent an installed release from offering itself as an update.

Upstream synchronization and automatic releases are not enabled.

## Installing the first persistently signed APK

Back up app settings before uninstalling an older APK signed with a temporary runner key or the upstream key. Install this fork's APK once; subsequent releases signed with the same persistent key can update it normally.
