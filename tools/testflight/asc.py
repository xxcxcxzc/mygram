#!/usr/bin/env python3
"""App Store Connect helper for building this Telegram fork for TestFlight.

Uses an App Store Connect API key (Users and Access > Integrations > App Store Connect API,
role "Admin" or "App Manager") so nothing has to be clicked in the developer portal except
the App Group (Apple's API cannot assign App Groups).

Commands:
  init-cert   Create a distribution certificate. Writes the private key and the certificate
              into --out. Run once, on your own computer.
  ensure-ids  Create the app's bundle identifiers and enable Push Notifications / App Groups.
  profiles    (Re)create App Store provisioning profiles for every bundle identifier and save
              them into --out. Run by CI before every build.

Credentials come from the environment:
  ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_P8 (the .p8 file contents) or ASC_KEY_PATH.
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.x509.oid import NameOID

API = "https://api.appstoreconnect.apple.com"

# Every target Telegram/BUILD signs (the watch app is not embedded).
BUNDLE_SUFFIXES = [
    "",
    ".Share",
    ".NotificationContent",
    ".NotificationService",
    ".Widget",
    ".SiriIntents",
    ".BroadcastUpload",
]

PROFILE_PREFIX = "VoiceTG AppStore"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def load_key_p8() -> bytes:
    content = os.environ.get("ASC_KEY_P8")
    if content:
        content = content.strip()
        if "BEGIN" not in content:
            # Allow the key to be stored base64-encoded.
            content = base64.b64decode(content).decode("utf-8")
        return content.encode("utf-8")
    path = os.environ.get("ASC_KEY_PATH")
    if path:
        with open(path, "rb") as f:
            return f.read()
    sys.exit("Set ASC_KEY_P8 (contents of the .p8 file) or ASC_KEY_PATH")


def make_token() -> str:
    key_id = os.environ.get("ASC_KEY_ID")
    issuer_id = os.environ.get("ASC_ISSUER_ID")
    if not key_id or not issuer_id:
        sys.exit("Set ASC_KEY_ID and ASC_ISSUER_ID")
    private_key = serialization.load_pem_private_key(load_key_p8(), password=None)
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": issuer_id, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    signing_input = b64url(json.dumps(header).encode()) + "." + b64url(json.dumps(payload).encode())
    der = private_key.sign(signing_input.encode("ascii"), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return signing_input + "." + b64url(signature)


class Api:
    def __init__(self):
        self.token = make_token()

    def request(self, method, path, body=None, ok_statuses=(200, 201, 204)):
        url = path if path.startswith("http") else API + path
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                parsed = json.loads(raw)
            except Exception:
                parsed = {"raw": raw.decode("utf-8", "replace")}
            if e.code in ok_statuses:
                return e.code, parsed
            return e.code, parsed

    def get_all(self, path):
        items = []
        url = path
        while url:
            status, body = self.request("GET", url)
            if status != 200:
                sys.exit("GET {} failed ({}): {}".format(url, status, json.dumps(body)))
            items.extend(body.get("data", []))
            url = body.get("links", {}).get("next")
        return items


def find_bundle_id(api, identifier):
    query = urllib.parse.urlencode({"filter[identifier]": identifier, "limit": 200})
    for item in api.get_all("/v1/bundleIds?" + query):
        if item["attributes"]["identifier"] == identifier:
            return item
    return None


def cmd_ensure_ids(args):
    api = Api()
    for suffix in BUNDLE_SUFFIXES:
        identifier = args.bundle_id + suffix
        item = find_bundle_id(api, identifier)
        if item is None:
            name = "VoiceTG" + (suffix.replace(".", " ") if suffix else " App")
            status, body = api.request("POST", "/v1/bundleIds", {
                "data": {
                    "type": "bundleIds",
                    "attributes": {"identifier": identifier, "name": name, "platform": "IOS"},
                }
            })
            if status not in (200, 201):
                sys.exit("Could not create bundle id {} ({}): {}".format(identifier, status, json.dumps(body)))
            item = body["data"]
            print("created bundle id", identifier)
        else:
            print("bundle id exists", identifier)

        capabilities = ["APP_GROUPS"]
        if suffix == "":
            capabilities.append("PUSH_NOTIFICATIONS")
        for capability in capabilities:
            status, body = api.request("POST", "/v1/bundleIdCapabilities", {
                "data": {
                    "type": "bundleIdCapabilities",
                    "attributes": {"capabilityType": capability},
                    "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": item["id"]}}},
                }
            })
            if status in (200, 201):
                print("  enabled", capability)
            elif status == 409:
                print("  already enabled", capability)
            else:
                print("  WARNING: could not enable {} ({}): {}".format(capability, status, json.dumps(body)))

    print()
    print("NEXT (manual, Apple's API cannot do this):")
    print("  developer.apple.com > Certificates, Identifiers & Profiles > Identifiers > App Groups:")
    print("  create the group  group.{}".format(args.bundle_id))
    print("  then open each of these identifiers, App Groups > Configure, tick that group, Save:")
    for suffix in BUNDLE_SUFFIXES:
        print("   ", args.bundle_id + suffix)


def cmd_init_cert(args):
    os.makedirs(args.out, exist_ok=True)
    key_path = os.path.join(args.out, "distribution_key.pem")
    cert_path = os.path.join(args.out, "distribution.cer")
    if os.path.exists(cert_path) and not args.force:
        sys.exit("{} already exists (use --force to make another one)".format(cert_path))

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(x509.Name([
            x509.NameAttribute(NameOID.COMMON_NAME, "VoiceTG Distribution"),
            x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
        ]))
        .sign(key, hashes.SHA256())
    )
    csr_b64 = base64.b64encode(csr.public_bytes(serialization.Encoding.DER)).decode("ascii")

    api = Api()
    status, body = api.request("POST", "/v1/certificates", {
        "data": {
            "type": "certificates",
            "attributes": {"certificateType": "DISTRIBUTION", "csrContent": csr_b64},
        }
    })
    if status not in (200, 201):
        sys.exit("Could not create the certificate ({}): {}".format(status, json.dumps(body)))
    cert_der = base64.b64decode(body["data"]["attributes"]["certificateContent"])

    with open(key_path, "wb") as f:
        f.write(key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        ))
    with open(cert_path, "wb") as f:
        f.write(cert_der)
    print("Saved", key_path)
    print("Saved", cert_path)
    print("Certificate id:", body["data"]["id"])


def find_certificate_id(api, cert_der):
    cert = x509.load_der_x509_certificate(cert_der)
    serial_hex = format(cert.serial_number, "X").lstrip("0")
    for item in api.get_all("/v1/certificates?limit=200"):
        serial = (item["attributes"].get("serialNumber") or "").upper().lstrip("0")
        if serial == serial_hex:
            return item["id"]
    sys.exit("The distribution certificate was not found in App Store Connect (revoked?)")


def cmd_profiles(args):
    with open(args.cert, "rb") as f:
        cert_data = f.read()
    if b"BEGIN CERTIFICATE" in cert_data:
        cert_der = x509.load_pem_x509_certificate(cert_data).public_bytes(serialization.Encoding.DER)
    else:
        cert_der = cert_data

    api = Api()
    certificate_id = find_certificate_id(api, cert_der)
    os.makedirs(args.out, exist_ok=True)

    existing = api.get_all("/v1/profiles?limit=200")
    missing_group = []
    for suffix in BUNDLE_SUFFIXES:
        identifier = args.bundle_id + suffix
        bundle = find_bundle_id(api, identifier)
        if bundle is None:
            sys.exit("Bundle id {} does not exist: run ensure-ids first".format(identifier))
        name = "{} {}".format(PROFILE_PREFIX, identifier)

        # Profiles are cheap: recreate them every time so they always include the current
        # certificate and the App Group configuration.
        for item in existing:
            if item["attributes"]["name"] == name:
                api.request("DELETE", "/v1/profiles/" + item["id"])

        status, body = api.request("POST", "/v1/profiles", {
            "data": {
                "type": "profiles",
                "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                    "certificates": {"data": [{"type": "certificates", "id": certificate_id}]},
                },
            }
        })
        if status not in (200, 201):
            sys.exit("Could not create profile for {} ({}): {}".format(identifier, status, json.dumps(body)))
        content = base64.b64decode(body["data"]["attributes"]["profileContent"])
        if ("group." + args.bundle_id).encode("utf-8") not in content:
            missing_group.append(identifier)
        file_name = "profile{}.mobileprovision".format(suffix.replace(".", "_") or "_App")
        with open(os.path.join(args.out, file_name), "wb") as f:
            f.write(content)
        print("profile saved for", identifier)

    if missing_group:
        print()
        print("ERROR: these identifiers are not in the App Group group.{}:".format(args.bundle_id))
        for identifier in missing_group:
            print("   ", identifier)
        print("Open developer.apple.com > Identifiers, enable App Groups for each and tick the group.")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("init-cert")
    p.add_argument("--out", required=True)
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_init_cert)

    p = sub.add_parser("ensure-ids")
    p.add_argument("--bundle-id", required=True)
    p.set_defaults(func=cmd_ensure_ids)

    p = sub.add_parser("profiles")
    p.add_argument("--bundle-id", required=True)
    p.add_argument("--cert", required=True, help="distribution certificate (.cer DER or PEM)")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_profiles)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
