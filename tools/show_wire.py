"""Pretty-print a wire document, for eyeballing engine output.

Reads the JSON file named on the command line and prints one line per display
line: its index, the source line it anchors to, and the reconstructed text.
"""

import json
import sys


def main() -> int:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)

    print(
        f"version={doc['version']} width={doc['width']} "
        f"styles={len(doc['styles'])} lines={len(doc['lines'])}"
    )
    print(f"source_map={doc['source_map']}")
    print("-" * 72)
    for i, line in enumerate(doc["lines"]):
        text = "".join(span[1] for span in line["spans"])
        source = "----" if line["source"] is None else f"{line['source']:>4}"
        print(f"{i:>4} src={source} |{text}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
