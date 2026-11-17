# SPDX-License-Identifier: MIT
"""Python's coverage for a command determinismo runs covered (`det-nodes exec --coverage`: a CI
job's tests). On PYTHONPATH before the node's own entries (nodes.zig), so every Python process
the command starts imports this as it starts and reports the lines of its own code: every file
but the interpreter's library and the installed packages, or the node's coverage set
(DETERMINISMO_COVERAGE). The repository changes nothing. Python 3.12+ (sys.monitoring); an older
one runs uncovered and says so. A sitecustomize of the node's own, which this one shadows, runs
after it."""
import os
import sys


def _coverage_start():
    if sys.version_info < (3, 12):
        sys.stderr.write("determinismo: Python %d.%d has no sys.monitoring: its code runs uncovered "
                         "(coverage needs 3.12 or later)\n" % sys.version_info[:2])
        return
    import sysconfig
    import determinismo
    paths = sysconfig.get_paths()
    library = {os.path.join(paths[name], "") for name in ("stdlib", "platstdlib", "purelib", "platlib") if paths.get(name)}
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "")
    # "<frozen importlib._bootstrap>", "<string>": code with no file of its own.
    determinismo.coverage_start(exclude=sorted(library) + [here, "<"])


def _next_sitecustomize():
    here = os.path.dirname(os.path.abspath(__file__))
    for entry in sys.path:
        directory = os.path.abspath(entry or os.curdir)
        path = os.path.join(directory, "sitecustomize.py")
        if directory == here or not os.path.isfile(path):
            continue
        import importlib.util
        spec = importlib.util.spec_from_file_location("sitecustomize_of_the_node", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return


_coverage_start()
_next_sitecustomize()
