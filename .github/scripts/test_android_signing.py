import unittest

import android_signing as signing


class ApkCertificateTests(unittest.TestCase):
    def test_sdk37_certificate_labels(self):
        fingerprint = signing.expected_fingerprint()
        self.assertTrue(signing.has_expected_signature(
            f"V2 Signer: certificate SHA-256 digest: {fingerprint}\n"
        ))

    def test_older_sdk_labels(self):
        fingerprint = signing.expected_fingerprint()
        self.assertTrue(signing.has_expected_signature(
            f"Signer #1 certificate SHA-256 digest: {fingerprint}\n"
        ))

    def test_same_certificate_in_multiple_schemes(self):
        fingerprint = signing.expected_fingerprint()
        self.assertTrue(signing.has_expected_signature(
            f"V2 Signer: certificate SHA-256 digest: {fingerprint}\n"
            f"V3.1 Signer: certificate SHA-256 digest: {fingerprint.upper()}\n"
        ))

    def test_other_certificates_are_rejected(self):
        fingerprint = signing.expected_fingerprint()
        wrong = "0" * 64
        self.assertFalse(signing.has_expected_signature(
            f"Signer #1 certificate SHA-256 digest: {wrong}\n"
        ))
        self.assertFalse(signing.has_expected_signature(
            f"Signer #1 certificate SHA-256 digest: {fingerprint}\n"
            f"Signer #2 certificate SHA-256 digest: {wrong}\n"
        ))

    def test_public_key_hash_cannot_impersonate_certificate_hash(self):
        fingerprint = signing.expected_fingerprint()
        self.assertFalse(signing.has_expected_signature(
            f"Signer #1 public key SHA-256 digest: {fingerprint}\n"
        ))
        self.assertFalse(signing.has_expected_signature(""))


if __name__ == "__main__":
    unittest.main()
