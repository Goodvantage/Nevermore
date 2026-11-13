"""Exercise the review workflow's JSON encoder without jq on PATH."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


WORKFLOW = Path(__file__).resolve().parents[2] / ".forgejo/workflows/zai-code-review.yml"
NODE = shutil.which("node")


class ReviewNoticeTests(unittest.TestCase):
    @unittest.skipUnless(NODE, "Node is required by the review runner but is not installed locally")
    def test_notice_preserves_text_without_jq(self):
        lines = [line.strip() for line in WORKFLOW.read_text().splitlines()
                 if line.strip().startswith(("jq -Rs ", "node -e "))]
        self.assertEqual(len(lines), 1, "expected one notice JSON encoder")
        command, separator, _ = lines[0].partition(' < "$notice"')
        self.assertTrue(separator, "the notice must reach the encoder through stdin")
        notice = 'Review "failed"\n`code` \\ path\n$(not-a-command) ${RUN_URL}\nGrüsse\n'
        with tempfile.TemporaryDirectory(prefix="NevermoreReviewNotice-") as directory:
            # Official Node images guarantee node, not jq. Do not inherit CI
            # credentials, Node options, or the developer's installed tools.
            Path(directory, "node").symlink_to(NODE)
            result = subprocess.run(["/bin/bash", "-c", command], input=notice,
                                    capture_output=True, text=True, timeout=15,
                                    env={"PATH": directory})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"body": notice})


if __name__ == "__main__":
    unittest.main()
