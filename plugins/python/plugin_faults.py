# SPDX-License-Identifier: MIT
"""A strategy that adds a fault of its own to a node: a command run in the node at random times,
drawn by the fault injector among the node's other faults (as a profile's custom fault). Given at
the machine's decision, so the run's tapes and record keep it and its replays need no plugin. An
example of a plugin's fault, and the e2e `plugin-faults` check's plugin.

    determinismo explore ... --strategy "python3 plugins/python/plugin_faults.py redis /usr/local/bin/redis-cli CLIENT PAUSE 200"
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from determinismo_strategy import serve  # noqa: E402


class PluginFaults:
    wants = ["machine"]
    decides = False

    def __init__(self, node, command):
        self.node = node
        self.command = command

    def machine(self, request):
        return {"custom_faults": [{"node": self.node, "command": self.command}]}


if __name__ == "__main__":
    serve(PluginFaults(sys.argv[1], " ".join(sys.argv[2:])), "plugin-faults")
