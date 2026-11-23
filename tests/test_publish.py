import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import publish


class PublishTests(unittest.TestCase):
    def test_rejects_existing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                publish.prepare("https://www.zldelf.cloud/api", directory, directory)

    def test_rejects_wrong_tool_revision_without_output(self):
        with tempfile.TemporaryDirectory() as directory:
            tool = Path(directory) / "tool"
            subprocess.run(["git", "init", "-q", "-b", "codex/test-fixture", str(tool)], check=True)
            (tool / "cli.lua").write_text("-- fixture")
            subprocess.run(["git", "-C", str(tool), "status", "--short"], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(tool), "add", "cli.lua"], check=True)
            subprocess.run(["git", "-C", str(tool), "-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-qm", "init: 初始化混淆器测试夹具"], check=True)
            output = Path(directory) / "public"
            with self.assertRaises(ValueError):
                publish.prepare("https://www.zldelf.cloud/api", output, tool)
            self.assertFalse(output.exists())

    @unittest.skipUnless(os.environ.get("HUB_PROMETHEUS_DIR"), "需提供固定版本混淆器路径")
    def test_real_obfuscation_publishes_only_allowlisted_assets(self):
        with tempfile.TemporaryDirectory() as directory:
            clone = Path(directory) / "standalone"
            clone.mkdir()
            root = Path(__file__).resolve().parents[1]
            for name in ("build.py", "publish.py", "obfuscate.lua", "VERSION"):
                shutil.copyfile(root / name, clone / name)
            shutil.copytree(root / "src", clone / "src")
            output = Path(directory) / "public"
            subprocess.run([
                sys.executable, str(clone / "publish.py"), "--output", str(output),
                "--prometheus-dir", os.environ["HUB_PROMETHEUS_DIR"],
                "--lua-bin", os.environ.get("HUB_LUA_BIN", "lua5.1"),
            ], cwd=directory, check=True, capture_output=True)
            self.assertEqual({path.name for path in output.iterdir()}, publish.PUBLIC_FILES)
            loader = (output / "loader.lua").read_text()
            self.assertNotIn("local pendingKey", loader)
            self.assertNotIn("local API =", loader)
            self.assertFalse((output / "scripts").exists())
            self.assertFalse((output / "manifest.json").exists())
            notice = (output / "NOTICE.txt").read_text()
            self.assertTrue(notice.startswith("ZS Hub " + (root / "VERSION").read_text().strip() + "\n"))
            self.assertIn(f"Loader: {publish.LOADER_URL}", notice)
            self.assertIn("API: https://www.zldelf.cloud/api", notice)
            digest = hashlib.sha256((output / "loader.lua").read_bytes()).hexdigest()
            self.assertIn(f"{digest}  loader.lua", (output / "SHA256SUMS").read_text())


if __name__ == "__main__":
    unittest.main()
