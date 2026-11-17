#!/usr/bin/env python3
# Regenerates ticket-vectors.json with an implementation independent of the Go verifier and
# the Node minter. Run from the repo root: python3 sdk/testdata/generate_ticket_vectors.py
#
# Ticket format: "v1." + base64url(payload JSON) + "." + base64url(HMAC-SHA256(secret, "v1." + payload)).
# Payload keys appear in this order, with no spaces: k, exp, ns, max, obj, chk.
import base64
import hashlib
import hmac
import json
import os

SECRET = "lumavault-test-ticket-secret-0123456789abcdef"
NOW = 1_800_000_000
SKEW = 30
KEY_ORDER = ["k", "exp", "ns", "max", "obj", "chk"]
CHUNK = "a" * 64


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def payload(claims):
    ordered = {k: claims[k] for k in KEY_ORDER if k in claims}
    return b64(json.dumps(ordered, separators=(",", ":")).encode("utf-8"))


def sign(body, secret=SECRET, prefix="v1."):
    signing_input = (prefix + body).encode("ascii")
    mac = hmac.new(secret.encode("utf-8"), signing_input, hashlib.sha256).digest()
    return prefix + body + "." + b64(mac)


def token(claims, **kwargs):
    return sign(payload(claims), **kwargs)


upload = {"k": "up", "exp": NOW + 86400, "ns": 1, "max": 5 * 1024 * 1024 * 1024}
read_obj = {"k": "rd", "exp": NOW + 21600, "obj": "obj-123"}
read_chk = {"k": "rd", "exp": NOW + 21600, "chk": CHUNK}

valid = [
    {"name": "upload", "token": token(upload), "claims": upload},
    {"name": "read object", "token": token(read_obj), "claims": read_obj},
    {"name": "read thumbnail chunk", "token": token(read_chk), "claims": read_chk},
    {
        "name": "expired within clock skew",
        "token": token({"k": "rd", "exp": NOW - SKEW, "obj": "obj-123"}),
        "claims": {"k": "rd", "exp": NOW - SKEW, "obj": "obj-123"},
    },
    {
        "name": "unknown fields are ignored",
        "token": sign(b64(json.dumps({"k": "rd", "exp": NOW + 60, "obj": "o", "future": 1}, separators=(",", ":")).encode())),
        "claims": {"k": "rd", "exp": NOW + 60, "obj": "o"},
    },
]

good = token(read_obj)
body, mac = good[3:].split(".")
flipped_mac = mac[:-1] + ("A" if mac[-1] != "A" else "B")
flipped_body = ("B" if body[0] != "B" else "C") + body[1:]

invalid = [
    {"name": "wrong prefix", "token": "v2." + good[3:], "error": "malformed"},
    {"name": "missing signature", "token": "v1." + body, "error": "malformed"},
    {"name": "bad base64 payload", "token": sign("!!!"), "error": "malformed"},
    {"name": "payload is not JSON", "token": sign(b64(b"not json")), "error": "malformed"},
    {"name": "signature changed", "token": "v1." + body + "." + flipped_mac, "error": "signature"},
    {"name": "payload changed", "token": "v1." + flipped_body + "." + mac, "error": "signature"},
    {"name": "signed with another secret", "token": token(read_obj, secret="another-secret-0123456789abcdef0123"), "error": "signature"},
    {"name": "expired", "token": token({"k": "rd", "exp": NOW - SKEW - 1, "obj": "o"}), "error": "expired"},
    {"name": "unknown kind", "token": token({"k": "zz", "exp": NOW + 60}), "error": "claims"},
    {"name": "missing expiry", "token": token({"k": "rd", "obj": "o"}), "error": "claims"},
    {"name": "read with object and chunk", "token": token({"k": "rd", "exp": NOW + 60, "obj": "o", "chk": CHUNK}), "error": "claims"},
    {"name": "read with neither", "token": token({"k": "rd", "exp": NOW + 60}), "error": "claims"},
    {"name": "read chunk not a SHA-256", "token": token({"k": "rd", "exp": NOW + 60, "chk": "ABC"}), "error": "claims"},
    {"name": "upload without namespace", "token": token({"k": "up", "exp": NOW + 60, "max": 1}), "error": "claims"},
    {"name": "upload without max size", "token": token({"k": "up", "exp": NOW + 60, "ns": 1}), "error": "claims"},
]

out = {
    "secret": SECRET,
    "now": NOW,
    "skewSeconds": SKEW,
    "valid": valid,
    "invalid": invalid,
}

path = os.path.join(os.path.dirname(__file__), "ticket-vectors.json")
with open(path, "w") as f:
    json.dump(out, f, indent=2)
    f.write("\n")
