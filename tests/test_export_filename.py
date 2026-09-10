#!/usr/bin/env python3
import importlib.util
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = REPO_ROOT / "network_monitor" / "export_excel.py"
spec = importlib.util.spec_from_file_location("export_excel", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


start = "2026-09-09 10:15:00"
end = "2026-09-09 10:16:30"
expected = Path("custom_test_20260909_101500_to_20260909_101630.xlsx")

assert module.add_range_to_output_path(Path("custom_test.xlsx"), start, end) == expected
assert module.add_range_to_output_path(expected, start, end) == expected
assert module.add_range_to_output_path(Path("all.xlsx"), None, None) == Path("all.xlsx")

try:
    module.add_range_to_output_path(Path("bad.xlsx"), end, start)
except ValueError:
    pass
else:
    raise AssertionError("An inverted export range must fail")

print("export filename tests passed.")
