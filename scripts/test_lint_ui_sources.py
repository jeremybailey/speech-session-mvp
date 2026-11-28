import unittest
from lint_ui_sources import violations

class SourceStyleLintTests(unittest.TestCase):
    def test_rejects_old_controls_and_whitespace_variants(self):
        for code in ['DisclosureGroup("Sources (1)") {}', 'DisclosureGroup ( \n"Source") {}', 'Button("Sources", systemImage: "link") {}', 'Text("Sources (2)")', 'Label("Source (1)", systemImage: "link")']:
            with self.subTest(code=code): self.assertTrue(violations(code))

    def test_accepts_shared_tags_and_unrelated_disclosures(self):
        for code in ['NavigationLink {} label: { StorySourceTag(title: title) }', 'Button {} label: { StorySourceTag(title: "Sources") }', 'DisclosureGroup("Details") {}', 'Text("Source unavailable")', 'DisclosureGroup("Source notes and history") {}']:
            with self.subTest(code=code): self.assertEqual(violations(code), [])
