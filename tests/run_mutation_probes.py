from pathlib import Path
import shutil, subprocess, tempfile

root = Path(__file__).resolve().parents[1]
mutations = [
    ("secret predicate gate", "if secret then return \"restricted\", \"aura-secret\" end", "if false then return \"restricted\", \"aura-secret\" end"),
    ("baseline suppression", "if forceBaseline or not observation.hasBaseline then", "if false then"),
    ("cap refresh detection", "observed.capRefreshes = IncrementCounter(observed.capRefreshes)", "observed.capRefreshes = observed.capRefreshes"),
    ("max-stack refresh gate", "and observation.maxStacks and stacks >= observation.maxStacks", "and stacks > 0"),
    ("disabled event cleanup", "EventFrame:UnregisterEvent(\"UNIT_AURA\")", "-- mutation: retained UNIT_AURA"),
    ("replacement-instance guard", "if observation.present and present", "if false and observation.present and present"),
    ("observed aggregate derivation", "db.observed.procs = SaturatingAdd(db.observed.stackGains, db.observed.capRefreshes)", "db.observed.procs = SanitizeCounter(db.observed.procs)"),
    ("proc aura identity", "includeSpellIDs = { [Addon.KM_SPELL_ID] = true },", "includeSpellIDs = { [Addon.KM_SPELL_ID] = true, [51128] = true },"),
]

passed = 0
for name, old, new in mutations:
    with tempfile.TemporaryDirectory() as td:
        dst = Path(td) / "repo"
        shutil.copytree(root, dst, ignore=shutil.ignore_patterns("libs", "run_mutation_probes.py"))
        targets = [dst / "Core.lua", dst / "UI.lua"]
        replaced = False
        for target in targets:
            text = target.read_text()
            if old in text:
                target.write_text(text.replace(old, new, 1))
                replaced = True
                break
        if not replaced:
            raise SystemExit(f"mutation source not found: {name}")
        result = subprocess.run(
            ["texlua", "tests/test_observation_12_1_5.lua"],
            cwd=dst,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if result.returncode == 0:
            print(f"MISS: {name}")
            print(result.stdout)
        else:
            passed += 1
            print(f"DETECTED: {name}")

if passed != len(mutations):
    raise SystemExit(f"{passed}/{len(mutations)} mutation probes detected")
print(f"PASS: {passed}/{len(mutations)} mutation probes detected")
