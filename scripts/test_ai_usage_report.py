"""Execute the actual Settings usage decoder/report offline with synthetic metadata."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'SpeechSessionApp/SettingsView.swift').read_text()
snapshot = 'struct AIUsageSnapshot' + source.split('private struct AIUsageSnapshot', 1)[1]
program = 'import Foundation\n' + snapshot + r'''
let raw = """
{"tracking_start":"2026-09-30T00:00:00Z","updated_at":"2026-09-30T12:00:00Z",
"today_nusd":"54000","last48_nusd":"54000","lifetime_nusd":"54000","unresolved_charges":1,
"timezone":"America/New_York","entries":[],
"latest_job":{"id":"synthetic-parent","state":"uncertain","cost_nusd":null,"record_count":6,"retry_count":0},
"budgets":[{"id":"pilot","limit_nusd":"1000000000","used_nusd":"54000","reserved_nusd":"22800000"}],
"source_excerpt":"SECRET_CLINICAL_TEXT","filename":"SECRET_FILENAME","credentials":"SECRET_CREDENTIAL"}
"""
let value = try JSONDecoder().decode(AIUsageSnapshot.self, from: Data(raw.utf8))
assert(value.latest_job?.id == "synthetic-parent")
assert(value.report.contains("synthetic-parent: uncertain, Unavailable"))
assert(value.budgets[0].remaining_nusd == "977146000")
assert(!value.report.contains("SECRET_"))
let unavailable = try JSONDecoder().decode(AIUsageSnapshot.self, from: Data(raw.replacingOccurrences(of: "\"tracking_start\":\"2026-09-30T00:00:00Z\"", with: "\"tracking_start\":null").utf8))
assert(unavailable.report.contains("Today: Unavailable"))
let malformed = AIUsageSnapshot.Budget(id: "pilot", limit_nusd: "unknown", used_nusd: "0", reserved_nusd: "0")
assert(malformed.remaining_nusd == nil)
print("Settings usage report, unknown charges, budget arithmetic and privacy passed")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'main.swift'
    path.write_text(program)
    subprocess.run(['swift', str(path)], check=True)
