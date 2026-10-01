#!/usr/bin/env python3
"""Prepare and verify the fixed fork key; install secrets from a private backup."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SECRET_NAMES = (
    "SIGN_KEYSTORE_BASE64", "KEYSTORE_PASSWORD", "KEY_ALIAS", "KEY_PASSWORD",
)


def expected_fingerprint():
    return (ROOT / ".github/android-signing.sha256").read_text().strip().lower()


def require_secrets():
    missing = [name for name in SECRET_NAMES if not os.environ.get(name)]
    if missing:
        raise ValueError(
            "Missing Actions secrets: " + ", ".join(missing)
            + ". Configure the persistent fork key; debug signing is disabled."
        )
    return {name: os.environ[name] for name in SECRET_NAMES}


def verify_keystore(path, alias, password):
    env = dict(os.environ, PILIPLUS_STORE_PASSWORD=password)
    with tempfile.TemporaryDirectory() as directory:
        certificate = Path(directory) / "certificate.der"
        result = subprocess.run(
            ["keytool", "-exportcert", "-keystore", str(path), "-alias", alias,
             "-storepass:env", "PILIPLUS_STORE_PASSWORD", "-file", str(certificate)],
            env=env, capture_output=True,
        )
        if result.returncode:
            raise ValueError("Cannot open the release keystore with the supplied alias/password.")
        fingerprint = hashlib.sha256(certificate.read_bytes()).hexdigest()
    if fingerprint != expected_fingerprint():
        raise ValueError("Keystore certificate differs from this fork's persistent signing key.")
    return fingerprint


def property_value(value):
    # java.util.Properties uses ISO-8859-1 and UTF-16 Unicode escapes.
    result = []
    encoded = value.encode("utf-16-be")
    for offset in range(0, len(encoded), 2):
        code = int.from_bytes(encoded[offset:offset + 2], "big")
        char = chr(code)
        if code < 32 or code > 126:
            result.append(f"\\u{code:04x}")
        elif char in "\\ =:#!":
            result.append("\\" + char)
        else:
            result.append(char)
    return "".join(result)


def prepare():
    secrets = require_secrets()
    directory = Path(os.environ["RUNNER_TEMP"]) / "piliplus-signing"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    keystore = directory / "release.p12"
    keystore.write_bytes(base64.b64decode(secrets["SIGN_KEYSTORE_BASE64"], validate=True))
    keystore.chmod(0o600)
    verify_keystore(keystore, secrets["KEY_ALIAS"], secrets["KEYSTORE_PASSWORD"])
    properties = {
        "storeFile": str(keystore.resolve()),
        "storePassword": secrets["KEYSTORE_PASSWORD"],
        "keyAlias": secrets["KEY_ALIAS"],
        "keyPassword": secrets["KEY_PASSWORD"],
    }
    target = ROOT / "android/key.properties"
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="ascii") as output:
        output.write("".join(
            f"{key}={property_value(value)}\n" for key, value in properties.items()
        ))
    target.chmod(0o600)
    print("Persistent Android signing key verified and configured.")


def has_expected_signature(output):
    # SDK 37 labels each scheme "V2 Signer:", while earlier apksigner versions
    # label the certificate "Signer #1". The same certificate may appear once
    # per verified signing scheme.
    digests = re.findall(
        r"^(?:Signer #\d+|V\d+(?:\.\d+)* Signer):? certificate SHA-256 digest: "
        r"([a-fA-F0-9]{64})$",
        output, flags=re.MULTILINE,
    )
    return {digest.lower() for digest in digests} == {expected_fingerprint()}


def verify_apks(directory):
    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ["ANDROID_SDK_ROOT"])
    tools = list((sdk / "build-tools").glob("*/apksigner"))
    if not tools:
        raise ValueError("Android SDK apksigner was not found.")
    apksigner = max(tools, key=lambda path: tuple(
        int(part) for part in re.findall(r"\d+", path.parent.name)
    ))
    apks = sorted(Path(directory).glob("app-*-release.apk"))
    if not apks:
        raise ValueError("No release APKs found for signature verification.")
    for apk in apks:
        result = subprocess.run(
            [str(apksigner), "verify", "--verbose", "--print-certs", str(apk)],
            capture_output=True, text=True,
        )
        if result.returncode or not has_expected_signature(result.stdout):
            raise ValueError(f"{apk.name} is not validly signed with this fork's release key.")
        print(f"Verified persistent release signature: {apk.name}")


def configure(keystore, credentials, repository):
    data = json.loads(Path(credentials).read_text())
    path = Path(keystore)
    verify_keystore(path, data["keyAlias"], data["storePassword"])
    secrets = {
        "SIGN_KEYSTORE_BASE64": base64.b64encode(path.read_bytes()).decode("ascii"),
        "KEYSTORE_PASSWORD": data["storePassword"],
        "KEY_ALIAS": data["keyAlias"],
        "KEY_PASSWORD": data["keyPassword"],
    }
    for name, value in secrets.items():
        result = subprocess.run(
            ["gh", "secret", "set", name, "--repo", repository],
            input=value, capture_output=True, text=True,
        )
        if result.returncode:
            # Secret values are passed on stdin, never on the command line.
            raise ValueError(f"Could not set {name}: {result.stderr.strip()}")
        print(f"Configured repository secret: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("prepare")
    verify = commands.add_parser("verify")
    verify.add_argument("directory")
    setup = commands.add_parser("configure")
    setup.add_argument("--keystore", required=True)
    setup.add_argument("--credentials", required=True)
    setup.add_argument("--repo", default="alvinmhng/PiliPlus")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare()
    elif args.command == "verify":
        verify_apks(args.directory)
    else:
        configure(args.keystore, args.credentials, args.repo)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        print(f"Android signing setup failed: {error}", file=sys.stderr)
        sys.exit(1)
