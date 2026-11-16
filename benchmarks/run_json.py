#!/usr/bin/env python3
"""Run the main pooled JSON document benchmark."""
import sys

from compare_json_documents import main, Ray


if __name__ == "__main__":
    try:
        main()
    except Ray.BenchmarkError as error:
        print("json document benchmark: " + str(error), file=sys.stderr)
        raise SystemExit(1)
