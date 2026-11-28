#!/usr/bin/env -S uv run --python 3.12 --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pykmip==0.11.0"]
# ///
# SPDX-License-Identifier: GPL-3.0
# Copyright (c) 2026 Schubert Anselme <schubert@anselm.es>
"""Probe a KMIP server for what the OpenBao kmip seal needs.

OpenBao requires KMIP 1.2 to 1.4, Encrypt and Decrypt, and an AES-GCM key
(or an RSA key pair with RSA-OAEP). This script checks exactly that against
any KMIP server, so it can be pointed at a candidate HSM or key manager later.

Subcommands:
  versions                  prints the KMIP versions the server offers
  query                     lists the operations the server advertises; exit 1 without Encrypt/Decrypt
  create                    creates and activates an AES-256 key, print its UID
  create-hsm UID            creates the AES-256 key inside the KMS's HSM under that UID (Cosmian)
  create-hsm-rsa UID        creates an RSA-2048 key pair inside the KMS's HSM (private key UID; public is UID_pk)
  roundtrip-rsa UID         RSA-OAEP-SHA256 encrypt then decrypt
  roundtrip UID             AES-GCM encrypt then decrypt with that key
"""

import argparse
import os
import sys

from kmip import enums
from kmip.core import objects
from kmip.core.factories.attributes import AttributeFactory
from kmip.core.messages import payloads
from kmip.pie.client import ProxyKmipClient


def client(args: argparse.Namespace) -> ProxyKmipClient:
    return ProxyKmipClient(
        hostname=args.host,
        port=args.port,
        cert=args.cert,
        key=args.key,
        ca=args.ca,
        ssl_version="PROTOCOL_TLSv1_2",
        kmip_version=enums.KMIPVersion.KMIP_1_4,
    )


def cmd_versions(args: argparse.Namespace) -> int:
    with client(args) as c:
        versions = c.proxy.discover_versions()
        print(f"discover_versions: {versions.result_status.value}")
        for v in versions.protocol_versions:
            print(f"  KMIP {v.major}.{v.minor}")
    return 0


def cmd_query(args: argparse.Namespace) -> int:
    with client(args) as c:
        result = c.proxy.query(query_functions=[enums.QueryFunction.QUERY_OPERATIONS])
        if result is None or result.operations is None:
            print("query: the server returned no operation list")
            return 1
        ops = {op.name for op in result.operations}
        print(f"operations advertised: {', '.join(sorted(ops))}")
        # OpenBao's kmip seal needs server-side Encrypt and Decrypt.
        missing = [name for name in ("ENCRYPT", "DECRYPT") if name not in ops]
        print(f"Encrypt/Decrypt: {'yes' if not missing else 'MISSING ' + ', '.join(missing)}")
        return 1 if missing else 0


def cmd_create(args: argparse.Namespace) -> int:
    with client(args) as c:
        uid = c.create(
            enums.CryptographicAlgorithm.AES,
            256,
            name="bao_seal_key",
            cryptographic_usage_mask=[
                enums.CryptographicUsageMask.ENCRYPT,
                enums.CryptographicUsageMask.DECRYPT,
            ],
        )
        c.activate(uid)
        print(uid)
    return 0


def cmd_create_hsm(args: argparse.Namespace) -> int:
    # Cosmian creates a key inside an HSM when the request carries the unique
    # identifier, in the form hsm::<model>::<slot>::<key id>. Only the KMS's HSM
    # admin user may do this.
    factory = AttributeFactory()
    attrs = [
        factory.create_attribute(enums.AttributeType.CRYPTOGRAPHIC_ALGORITHM, enums.CryptographicAlgorithm.AES),
        factory.create_attribute(enums.AttributeType.CRYPTOGRAPHIC_LENGTH, 256),
        factory.create_attribute(
            enums.AttributeType.CRYPTOGRAPHIC_USAGE_MASK,
            [enums.CryptographicUsageMask.ENCRYPT, enums.CryptographicUsageMask.DECRYPT],
        ),
        factory.create_attribute(enums.AttributeType.UNIQUE_IDENTIFIER, args.uid),
    ]
    with client(args) as c:
        resp = c.proxy.send_request_payload(
            enums.Operation.CREATE,
            payloads.CreateRequestPayload(
                object_type=enums.ObjectType.SYMMETRIC_KEY,
                template_attribute=objects.TemplateAttribute(attributes=attrs),
            ),
        )
        print(resp.unique_identifier)
    return 0


def cmd_create_hsm_rsa(args: argparse.Namespace) -> int:
    # RSA key pair inside the HSM. Cosmian names the public key <uid>_pk.
    factory = AttributeFactory()
    common = [
        factory.create_attribute(enums.AttributeType.CRYPTOGRAPHIC_ALGORITHM, enums.CryptographicAlgorithm.RSA),
        factory.create_attribute(enums.AttributeType.CRYPTOGRAPHIC_LENGTH, 2048),
    ]
    private = [
        factory.create_attribute(enums.AttributeType.CRYPTOGRAPHIC_USAGE_MASK, [enums.CryptographicUsageMask.DECRYPT]),
        factory.create_attribute(enums.AttributeType.UNIQUE_IDENTIFIER, args.uid),
    ]
    public = [
        factory.create_attribute(enums.AttributeType.CRYPTOGRAPHIC_USAGE_MASK, [enums.CryptographicUsageMask.ENCRYPT]),
    ]
    with client(args) as c:
        resp = c.proxy.send_request_payload(
            enums.Operation.CREATE_KEY_PAIR,
            payloads.CreateKeyPairRequestPayload(
                common_template_attribute=objects.TemplateAttribute(
                    attributes=common, tag=enums.Tags.COMMON_TEMPLATE_ATTRIBUTE
                ),
                private_key_template_attribute=objects.TemplateAttribute(
                    attributes=private, tag=enums.Tags.PRIVATE_KEY_TEMPLATE_ATTRIBUTE
                ),
                public_key_template_attribute=objects.TemplateAttribute(
                    attributes=public, tag=enums.Tags.PUBLIC_KEY_TEMPLATE_ATTRIBUTE
                ),
            ),
        )
        print(f"public key: {resp.public_key_unique_identifier}")
        print(resp.private_key_unique_identifier)
    return 0


def cmd_roundtrip_rsa(args: argparse.Namespace) -> int:
    # RSA-OAEP with SHA-256, the seal's RSA_OAEP_SHA256. Report which key ID the
    # server accepts for Encrypt: the private key's (what OpenBao is configured
    # with) or the public key's (<uid>_pk).
    hash_alg = {
        "sha1": enums.HashingAlgorithm.SHA_1,
        "sha256": enums.HashingAlgorithm.SHA_256,
        "sha384": enums.HashingAlgorithm.SHA_384,
        "sha512": enums.HashingAlgorithm.SHA_512,
    }[args.hash]
    params = objects.CryptographicParameters(
        cryptographic_algorithm=enums.CryptographicAlgorithm.RSA,
        padding_method=enums.PaddingMethod.OAEP,
        hashing_algorithm=hash_alg,
    )
    plaintext = b"openbao-seal-probe"
    with client(args) as c:
        enc = None
        for target in (args.uid, f"{args.uid}_pk"):
            try:
                enc = c.proxy.send_request_payload(
                    enums.Operation.ENCRYPT,
                    payloads.EncryptRequestPayload(
                        unique_identifier=target, cryptographic_parameters=params, data=plaintext
                    ),
                )
                print(f"encrypt accepted key id: {target}")
                break
            except Exception as e:  # noqa: BLE001 - report and try the next id
                print(f"encrypt with {target} failed: {e}")
        if enc is None:
            return 1
        dec = c.proxy.send_request_payload(
            enums.Operation.DECRYPT,
            payloads.DecryptRequestPayload(
                unique_identifier=args.uid, cryptographic_parameters=params, data=enc.data
            ),
        )
    ok = dec.data == plaintext
    print(f"roundtrip RSA-OAEP-{args.hash} (encrypt + decrypt with {args.uid}): {'ok' if ok else 'MISMATCH'}")
    return 0 if ok else 1


def cmd_roundtrip(args: argparse.Namespace) -> int:
    # The high-level pie client drops the GCM auth tag, so use request payloads.
    params = objects.CryptographicParameters(
        cryptographic_algorithm=enums.CryptographicAlgorithm.AES,
        block_cipher_mode=enums.BlockCipherMode.GCM,
        tag_length=16,
    )
    plaintext = b"openbao-seal-probe"
    with client(args) as c:
        enc = c.proxy.send_request_payload(
            enums.Operation.ENCRYPT,
            payloads.EncryptRequestPayload(
                unique_identifier=args.uid, cryptographic_parameters=params, data=plaintext
            ),
        )
        dec = c.proxy.send_request_payload(
            enums.Operation.DECRYPT,
            payloads.DecryptRequestPayload(
                unique_identifier=args.uid,
                cryptographic_parameters=params,
                data=enc.data,
                iv_counter_nonce=enc.iv_counter_nonce,
                auth_tag=enc.auth_tag,
            ),
        )
    ok = dec.data == plaintext
    print(f"roundtrip AES-GCM (encrypt + decrypt): {'ok' if ok else 'MISMATCH'}")
    return 0 if ok else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    p.add_argument("--host", default=os.environ.get("KMIP_HOST", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.environ.get("KMIP_PORT", "5696")))
    p.add_argument("--cert", default=os.environ.get("KMIP_CLIENT_CERT"))
    p.add_argument("--key", default=os.environ.get("KMIP_CLIENT_KEY"))
    p.add_argument("--ca", default=os.environ.get("KMIP_CA_CERT"))
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("versions").set_defaults(fn=cmd_versions)
    sub.add_parser("query").set_defaults(fn=cmd_query)
    sub.add_parser("create").set_defaults(fn=cmd_create)
    ch = sub.add_parser("create-hsm")
    ch.add_argument("uid", help="hsm::<model>::<slot>::<key id>")
    ch.set_defaults(fn=cmd_create_hsm)
    cr = sub.add_parser("create-hsm-rsa")
    cr.add_argument("uid", help="hsm::<slot>::<key id> (private key; the public key becomes <uid>_pk)")
    cr.set_defaults(fn=cmd_create_hsm_rsa)
    rr = sub.add_parser("roundtrip-rsa")
    rr.add_argument("uid")
    rr.add_argument("--hash", default="sha256", choices=["sha1", "sha256", "sha384", "sha512"])
    rr.set_defaults(fn=cmd_roundtrip_rsa)
    r = sub.add_parser("roundtrip")
    r.add_argument("uid")
    r.set_defaults(fn=cmd_roundtrip)
    args = p.parse_args()
    for flag, env in (("cert", "KMIP_CLIENT_CERT"), ("key", "KMIP_CLIENT_KEY"), ("ca", "KMIP_CA_CERT")):
        if not getattr(args, flag):
            p.error(f"--{flag} or {env} is required")
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
