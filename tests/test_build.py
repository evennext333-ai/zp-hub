import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build


class BuildTests(unittest.TestCase):
    def test_existing_api_prefix_is_not_duplicated(self):
        self.assertEqual(build.api_url("https://www.zldelf.cloud/api/"), "https://www.zldelf.cloud")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "release"
            build.build(build.DEFAULT_API_URL, output)
            source = (output / "loader.lua").read_text()
            self.assertIn('local API = [[https://www.zldelf.cloud]]', source)
            self.assertIn(f'local FALLBACK_API = [[{build.DEFAULT_FALLBACK_API_URL}]]', source)
            self.assertNotIn("/api/api", source)

    def test_public_bundle_has_only_static_assets_and_checked_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "bundle"
            metadata = build.build(build.DEFAULT_API_URL, output)
            self.assertEqual({p.name for p in output.iterdir()}, set(build.PUBLIC_ASSETS) | {"hub.json"})
            self.assertEqual(json.loads((output / "hub.json").read_text()), metadata)
            for name, digest in metadata["files"].items():
                self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), digest)
            with self.assertRaises(ValueError):
                build.build(build.DEFAULT_API_URL, output)

    def test_rejects_unsafe_url(self):
        for url in ("http://example.com", "https://a:b@example.com", "https://example.com?token=x",
                    "https://exam ple.com", "https://example.com:abc", "https://example.com:99999",
                    "https://example.com:0", "https://example.com/api/hub"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                build.api_url(url)

    def test_standalone_copy_builds_without_sibling_repositories(self):
        with tempfile.TemporaryDirectory() as directory:
            clone = Path(directory) / "standalone"
            clone.mkdir()
            shutil.copyfile(build.ROOT / "build.py", clone / "build.py")
            shutil.copyfile(build.ROOT / "VERSION", clone / "VERSION")
            shutil.copytree(build.ROOT / "src", clone / "src")
            output = Path(directory) / "bundle"
            subprocess.run([sys.executable, str(clone / "build.py"), "--output", str(output)],
                           cwd=directory, check=True, capture_output=True)
            self.assertTrue((output / "loader.lua").is_file())
            self.assertFalse((output / "scripts").exists())

    def test_failed_obfuscation_never_publishes_plaintext(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "failed"
            with patch.object(build, "obfuscate", side_effect=ValueError("fixture failure")):
                with self.assertRaises(ValueError):
                    build.build(build.DEFAULT_API_URL, output, Path(directory))
            self.assertFalse(output.exists())
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_fallback_can_be_disabled_or_deduplicated_and_rejects_unsafe_urls(self):
        for fallback in ("", build.DEFAULT_API_URL):
            with self.subTest(fallback=fallback), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "bundle"
                metadata = build.build(build.DEFAULT_API_URL, output, fallback_api=fallback)
                self.assertNotIn("fallbackApi", metadata)
                self.assertNotIn("local FALLBACK_API =", (output / "loader.lua").read_text())
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            build.build(build.DEFAULT_API_URL, Path(directory) / "bundle", fallback_api="http://example.com")

    def test_custom_api_never_implicitly_sends_credentials_to_production_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "custom"
            metadata = build.build("https://staging.example/api", output)
            self.assertNotIn("fallbackApi", metadata)
            self.assertNotIn(build.DEFAULT_FALLBACK_API_URL, (output / "loader.lua").read_text())
            explicit = build.build("https://staging.example", Path(directory) / "explicit",
                                   fallback_api="https://edge.example/api/")
            self.assertEqual(explicit["fallbackApi"], "https://edge.example")

    def test_lua_literal_handles_closing_delimiters(self):
        self.assertEqual(build.lua_literal("a]]b"), "[=[a]]b]=]")


if __name__ == "__main__":
    unittest.main()
