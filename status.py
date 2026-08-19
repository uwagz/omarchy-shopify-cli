#!/usr/bin/env python3
"""Entry point for the Omarchy Shopify CLI status helper.

The implementation lives in shopify_cli_status.py so its bytecode can be cached
(PYTHONPYCACHEPREFIX, set by Service.qml) outside the plugin directory — a
__pycache__ inside it would trip the shell's plugin hot-reload watcher.
"""
import sys

from shopify_cli_status import main

if __name__ == "__main__":
  sys.exit(main(sys.argv[1:]))
