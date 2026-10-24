#!/usr/bin/env python3
"""Headless Lua protocol regressions; uses an already-built runner, never builds.

Run: python3 Tests/PluginRuntimeTests.py [--runner /path/to/SpotlitePluginRunner]
Optional --bootstrap selects another runtime for comparing regressions.
"""

import argparse
import contextlib
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import statistics
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNNER = None
BOOTSTRAP = ROOT / "Resources/PluginRuntime/bootstrap.lua"

PLUGIN = r'''
local s = require("spotlite")
local ids, closed = {}, 0
local function guard()
    return setmetatable({}, {__close = function() closed = closed + 1 end})
end
return {
    start = function(args)
        assert(require("fixture").value == "source package module")
        print("plugin print stays off protocol")
        io.stdout:write("plugin stdout stays off protocol\n"); io.stdout:flush()
        if args.mode == "nested" then
            ids[1] = s.background(function()
                ids[2] = s.background(function()
                    ids[3] = s.background(function() s.log("deepest child") end)
                end)
            end)
        elseif args.mode == "cancel_ready" then
            ids[1] = s.background(function() error("cancelled task ran") end)
            assert(s.cancel_background(ids[1]))
            ids[2] = s.background(function() s.log("survivor") end)
        elseif args.mode == "waiting" then
            ids[1] = s.background(function()
                local resource <close> = guard()
                s.timers.sleep({seconds = 3600})
                error("cancelled task resumed")
            end)
        elseif args.mode == "error" then
            ids[1] = s.background(function()
                local resource <close> = guard()
                error("intentional background failure")
            end)
        end
    end,
    inspect = function()
        local retained = s.json.array()
        for i, id in ipairs(ids) do retained[i] = s.cancel_background(id) end
        return {retained = retained, closed = closed}
    end,
    cancel_task = function() return s.cancel_background(ids[1]) end,
    call = function(args)
        local resource <close> = guard()
        if args.section == "log" then return s.log("test log") end
        return s[args.section][args.method](args.arguments)
    end,
    decode = function(args)
        local ok, value = pcall(s.json.decode, args.text)
        return {ok = ok, value = value}
    end,
    benchmark = function()
        local function measure(count)
            local text = "[" .. string.rep("1234567,", count - 1) .. "1234567]"
            local samples = s.json.array()
            for i = 1, 3 do
                collectgarbage("collect")
                local start = os.clock()
                local values = s.json.decode(text)
                samples[i] = os.clock() - start
                assert(#values == count and values[count] == 1234567)
            end
            return {bytes = #text, samples = samples}
        end
        return {small = measure(16000), large = measure(96000)}
    end,
}
'''


class Runner:
    """A simulated host with bounded reads and process-group cleanup on failure."""

    def __init__(self, package):
        self.process = subprocess.Popen(
            [str(RUNNER), str(BOOTSTRAP), str(package)], cwd=package,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ, "protocol")
        self.selector.register(self.process.stderr, selectors.EVENT_READ, "log")
        self.buffer = b""
        self.logs = bytearray()
        self.events = []
        self.active = set()

    def send(self, message):
        # Fixtures only send small requests, safely below the pipe capacity.
        self.process.stdin.write(json.dumps(message, ensure_ascii=True).encode() + b"\n")
        self.process.stdin.flush()

    def receive(self, timeout=5):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError("runner response timed out; logs: " + self.logs.decode(errors="replace"))
            for key, _ in self.selector.select(remaining):
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    self.selector.unregister(key.fileobj)
                    if key.data == "protocol":
                        raise AssertionError("runner closed protocol; logs: " + self.logs.decode(errors="replace"))
                elif key.data == "protocol":
                    self.buffer += data
                else:
                    self.logs.extend(data)
            if len(self.buffer) > 4 * 1024 * 1024:
                raise AssertionError("oversized runner message")
        line, self.buffer = self.buffer.split(b"\n", 1)
        message = json.loads(line)
        self.events.append(message)
        method = message.get("method", "")
        if method.startswith("background."):
            task = message["params"]["id"]
            if method == "background.started":
                if task in self.active:
                    raise AssertionError("duplicate background ID")
                self.active.add(task)
            else:
                self.active.discard(task)
        return message

    def until(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            message = self.receive(max(0, deadline - time.monotonic()))
            if predicate(message):
                return message

    def request(self, method, params=None, timeout=5):
        request_id = "test:" + str(len(self.events))
        self.send({"id": request_id, "method": method, "params": params or {}})
        return self.until(lambda message: message.get("id") == request_id, timeout)

    def initialize(self, mode="none"):
        return self.request("initialize", {"entry": "main.lua", "mode": mode})

    def host_call(self, method):
        # Never send input to coax a background into starting. A log is itself
        # an asynchronous host call and must get its own reply after it arrives.
        return self.until(lambda message: message.get("method") == method and "id" in message)

    def reply(self, message, **response):
        self.send({"id": message["id"], **response})

    def finish_backgrounds(self):
        while self.active:
            message = self.receive()
            if not message.get("method", "").startswith("background."):
                raise AssertionError("unexpected message while completing backgrounds: " + repr(message))

    def close(self):
        try:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                pass
        finally:
            # Runner owns a process group (not a session); also kill its PID
            # in case teardown races with the runner's initial setpgid call.
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if self.process.poll() is None:
                self.process.kill()
            self.process.wait(timeout=2)
            self.selector.close()
            self.logs.extend(self.process.stderr.read())
            self.process.stdout.close()
            self.process.stderr.close()


class RuntimeTests(unittest.TestCase):
    @contextlib.contextmanager
    def runner(self):
        with tempfile.TemporaryDirectory(prefix="spotlite-lua-test-") as folder:
            package = Path(folder)
            (package / "main.lua").write_text(PLUGIN)
            (package / "fixture").mkdir()
            (package / "fixture/init.lua").write_text('return {value = "source package module"}')
            runner = Runner(package)
            try:
                yield runner
            finally:
                runner.close()

    def assert_released(self, runner, count, closed=0):
        runner.finish_backgrounds()
        self.assertEqual(runner.active, set())
        state = runner.request("inspect")["result"]
        self.assertEqual(state, {"retained": [False] * count, "closed": closed})
        finished = [e["params"]["id"] for e in runner.events if e.get("method") == "background.finished"]
        self.assertEqual(len(finished), count)
        self.assertEqual(len(set(finished)), count)

    def test_nested_backgrounds_start_without_more_input(self):
        with self.runner() as runner:
            self.assertIs(runner.initialize("nested")["result"], True)
            message = runner.host_call("log")
            self.assertEqual(message["params"]["arguments"]["message"], "deepest child")
            self.assertEqual(len([e for e in runner.events if e.get("method") == "background.started"]), 3)
            runner.reply(message, result=None)
            self.assert_released(runner, 3)
        self.assertIn(b"plugin print stays off protocol", runner.logs)
        self.assertIn(b"plugin stdout stays off protocol", runner.logs)

    def test_cancelling_ready_background_preserves_other_work(self):
        with self.runner() as runner:
            runner.initialize("cancel_ready")
            message = runner.host_call("log")
            self.assertEqual(message["params"]["arguments"]["message"], "survivor")
            runner.reply(message, result=None)
            self.assert_released(runner, 2)
            self.assertEqual(len([e for e in runner.events if e.get("method") == "background.cancelled"]), 1)

    def test_cancelling_waiting_background_closes_resources_and_ignores_late_reply(self):
        with self.runner() as runner:
            runner.initialize("waiting")
            waiting = runner.host_call("timers.sleep")
            self.assertIs(runner.request("cancel_task")["result"], True)
            runner.reply(waiting, result=True)
            self.assert_released(runner, 1, closed=1)
            self.assertIs(runner.request("cancel_task")["result"], False)

    def test_background_error_closes_resources(self):
        with self.runner() as runner:
            runner.initialize("error")
            message = runner.until(lambda e: e.get("method") == "log")
            self.assertNotIn("id", message)
            self.assertIn("intentional background failure", message["params"]["message"])
            self.assertIn("stack traceback", message["params"]["message"])
            self.assert_released(runner, 1, closed=1)

    def test_host_cancellation_closes_foreground_and_ignores_late_reply(self):
        with self.runner() as runner:
            runner.initialize()
            runner.send({"id": "foreground", "method": "call", "params": {"section": "timers", "method": "sleep"}})
            waiting = runner.host_call("timers.sleep")
            runner.send({"method": "cancel", "params": {"id": "foreground"}})
            runner.reply(waiting, result=True)
            self.assertEqual(runner.request("inspect")["result"]["closed"], 1)
            self.assertFalse(any(e.get("id") == "foreground" for e in runner.events))

    def test_host_errors_and_false_or_null_results(self):
        for section, method in [("log", None), ("http", "request"), ("settings", "get")]:
            with self.subTest(section=section), self.runner() as runner:
                runner.initialize()
                for result in (False, None):
                    runner.send({"id": "call", "method": "call", "params": {"section": section, "method": method}})
                    call = runner.host_call("log" if section == "log" else section + "." + method)
                    runner.reply(call, result=result)
                    self.assertIs(runner.until(lambda e: e.get("id") == "call")["result"], result)
                runner.send({"id": "call", "method": "call", "params": {"section": section, "method": method}})
                call = runner.host_call("log" if section == "log" else section + "." + method)
                runner.reply(call, error="intentional host failure")
                error = runner.until(lambda e: e.get("id") == "call")["error"]
                self.assertIn("intentional host failure", error)
                self.assertIn("main.lua:", error)
                self.assertIn("stack traceback", error)
                self.assertEqual(runner.request("inspect")["result"]["closed"], 3)

    def test_json_correctness(self):
        valid = [
            "null", "false", "true", "[]", "{}", "0", "-0", "-12", "1.25", "-0.125",
            "1e3", "-1.25E+3", "2E-4", "[0,1,-2,3.5,4e2,null,false]",
            '{"false":false,"null":null,"array":[],"object":{}}',
            r'"\u0041\u00e9\ud83d\ude00"', r'"\"\\\/\b\f\n\r\t"', '"é😀"',
            " \t\r\n[1, 2, 3] \n",
        ]
        invalid = [
            "", "01", "-01", "00.1", "1.", "1e", "1e+", "1e-", "1.e2", ".1", "-.1",
            "+1", "--1", "1e309", "-1e309", "NaN", "Infinity", "[1,]", "[1 2]", "[1e+]",
            '{"x":}', "truefalse", "null 1", r'"\ud800"', r'"\ud800\u0041"',
            r'"\udc00"', r'"\uZZZZ"', r'"\u123"', r'"\x41"', '"raw\nnewline"',
        ]
        with self.runner() as runner:
            runner.initialize()
            for text in valid:
                with self.subTest(text=text):
                    result = runner.request("decode", {"text": text})["result"]
                    self.assertIs(result["ok"], True)
                    self.assertEqual(result["value"], json.loads(text))
            for text in invalid:
                with self.subTest(text=text):
                    result = runner.request("decode", {"text": text})["result"]
                    self.assertIs(result["ok"], False)
                    self.assertIn("at byte", result["value"])

    def test_numeric_array_decode_scales_linearly(self):
        with self.runner() as runner:
            runner.initialize()
            result = runner.request("benchmark", timeout=45)["result"]
            small, large = (statistics.median(result[size]["samples"]) for size in ("small", "large"))
            self.assertLess(result["large"]["bytes"], 1024 * 1024)
            # Six times the input permits 14x CPU time plus timer noise. The
            # suffix-copy regression grows quadratically, approaching 36x.
            self.assertLessEqual(large, small * 14 + 0.025, result)
            print(f"\nJSON decode: {result['small']['bytes']} B {small:.4f}s; "
                  f"{result['large']['bytes']} B {large:.4f}s; ratio {large / max(small, 1e-9):.2f}x")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", type=Path)
    parser.add_argument("--bootstrap", type=Path, default=BOOTSTRAP)
    options, tests = parser.parse_known_args()
    candidates = [options.runner] if options.runner else [
        ROOT / ".build/release/SpotlitePluginRunner",
        ROOT / ".build/debug/SpotlitePluginRunner",
        ROOT / "build/Spotlite.app/Contents/Helpers/SpotlitePluginRunner",
        shutil.which("SpotlitePluginRunner"),
    ]
    RUNNER = next((Path(path).resolve() for path in candidates if path and os.access(path, os.X_OK)), None)
    if RUNNER is None:
        parser.error("existing SpotlitePluginRunner not found; pass --runner (this script does not build)")
    BOOTSTRAP = options.bootstrap.resolve()
    if not BOOTSTRAP.is_file():
        parser.error("bootstrap.lua not found: " + str(BOOTSTRAP))
    unittest.main(argv=[__file__, *tests])
