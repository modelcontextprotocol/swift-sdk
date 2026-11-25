"""py-interop-client: runs the interop check battery (interop/README.md)
against an MCP server built with any SDK, using the Python SDK, and prints
one JSON object per line: a "meta" line, then one line per check.

    python client.py --url http://127.0.0.1:3001/mcp [--era handshake|stateless|auto]
    python client.py --era stateless --stdio path/to/server [args...]
    python client.py --profile tool --tool greet --args '{"name":"Py"}' --expect Py --stdio ...

Profiles: everything, advanced (concurrency, cancellation, notifications,
subscriptions, transport edges), connect (--expect-era
handshake|stateless|unsupported), session (--pause-file; the runner restarts
the server), tasks (task tools of the Swift everything-server), tool.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import sys
from collections import Counter
from contextlib import AsyncExitStack
from pathlib import Path
from typing import Any, Awaitable, Callable

import anyio

from mcp import Client, StdioServerParameters, types
from mcp.shared.exceptions import MCPError

counts: Counter[str] = Counter()
tokens: Counter[str] = Counter()


def emit(obj: dict[str, Any]) -> None:
    print(json.dumps(obj, sort_keys=True), flush=True)


class CheckFailed(Exception):
    pass


def rejects_protocol_version(text: str) -> bool:
    """-32022, or a message that says the protocol version is unsupported (not, say, a media type)."""
    lower = text.lower()
    return "-32022" in text or ("protocol version" in lower and ("unsupported" in lower or "not supported" in lower))


LOST_SESSION = re.compile(r"session (not found|expired|terminated)", re.IGNORECASE)


class Skip(Exception):
    """The check does not apply to this server."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CheckFailed(message)


def texts(content: list[Any]) -> str:
    return " ".join(c.text for c in content if isinstance(c, types.TextContent))


def kinds(content: list[Any]) -> list[str]:
    names = {
        types.TextContent: "text",
        types.ImageContent: "image",
        types.AudioContent: "audio",
        types.EmbeddedResource: "resource",
        types.ResourceLink: "resource_link",
    }
    return [names.get(type(c), type(c).__name__) for c in content]


def answer(schema: dict[str, Any]) -> dict[str, Any]:
    """A plausible answer for every field of an elicitation form."""
    out: dict[str, Any] = {}
    for name, prop in (schema.get("properties") or {}).items():
        if prop.get("enum"):
            out[name] = prop["enum"][0]
        elif prop.get("oneOf"):
            out[name] = prop["oneOf"][0].get("const")
        elif isinstance(prop.get("items"), dict) and (prop["items"].get("enum") or prop["items"].get("anyOf")):
            items = prop["items"]
            out[name] = [items["enum"][0]] if items.get("enum") else [items["anyOf"][0].get("const")]
        elif prop.get("type") in ("number", "integer"):
            out[name] = 1
        elif prop.get("type") == "boolean":
            out[name] = True
        else:
            out[name] = "interop@example.com" if "email" in name.lower() else "interop"
    return out


async def on_sampling(context: Any, params: types.CreateMessageRequestParams) -> types.CreateMessageResult:
    counts["sampling"] += 1
    return types.CreateMessageResult(
        role="assistant",
        content=types.TextContent(type="text", text="interop sampling reply"),
        model="interop-model",
        stop_reason="endTurn",
    )


async def on_elicitation(context: Any, params: types.ElicitRequestParams) -> types.ElicitResult:
    counts["elicitation"] += 1
    schema = getattr(params, "requested_schema", None) or {}
    if hasattr(schema, "model_dump"):
        schema = schema.model_dump(by_alias=True, exclude_none=True)
    return types.ElicitResult(action="accept", content=answer(schema))


async def on_roots(context: Any) -> types.ListRootsResult:
    counts["roots"] += 1
    return types.ListRootsResult(roots=[types.Root(uri="file:///tmp/interop", name="interop")])


async def on_log(params: types.LoggingMessageNotificationParams) -> None:
    counts["logs"] += 1


async def on_progress(progress: float, total: float | None, message: str | None) -> None:
    counts["progress"] += 1


def progress_for(token: str) -> Callable[[float, float | None, str | None], Awaitable[None]]:
    async def callback(progress: float, total: float | None, message: str | None) -> None:
        counts["progress"] += 1
        tokens[token] += 1

    return callback


def count_event(name: str) -> None:
    if "Tool" in name:
        counts["tools-changed"] += 1
    elif "Prompt" in name:
        counts["prompts-changed"] += 1
    elif "ResourceUpdated" in name:
        counts["resource-updated"] += 1


async def on_message(message: Any) -> None:
    if isinstance(message, types.ToolListChangedNotification):
        count_event("Tool")
    elif isinstance(message, types.PromptListChangedNotification):
        count_event("Prompt")
    elif isinstance(message, types.ResourceUpdatedNotification):
        count_event("ResourceUpdated")


async def wait_for(seconds: float, condition: Callable[[], bool]) -> bool:
    with anyio.move_on_after(seconds):
        while not condition():
            await anyio.sleep(0.05)
    return condition()


async def pause(path: str) -> None:
    """Tell the runner the session is ready, then wait until it writes "go"."""
    file = Path(path)
    file.write_text("ready\n")
    for _ in range(1200):
        if "go" in file.read_text():
            return
        await anyio.sleep(0.05)
    raise CheckFailed("the runner did not resume")


def make_client(target: Any, mode: str) -> Client:
    return Client(
        target,
        mode=mode,
        sampling_callback=on_sampling,
        elicitation_callback=on_elicitation,
        list_roots_callback=on_roots,
        logging_callback=on_log,
        message_handler=on_message,
        log_level="debug",
        client_info=types.Implementation(name="py-interop-client", version="1.0.0"),
    )


class Battery:
    def __init__(self, client: Client, era: str, timeout: float, is_http: bool = False) -> None:
        self.client = client
        self.era = era
        self.timeout = timeout
        self.is_http = is_http

    async def check(self, check_id: str, body: Callable[[], Awaitable[str]], only: str | None = None) -> None:
        if only and only != self.era:
            emit({"check": check_id, "status": "skip", "detail": f"{only} only"})
            return
        try:
            with anyio.fail_after(self.timeout):
                detail = await body()
            emit({"check": check_id, "status": "pass", "detail": detail})
        except Skip as reason:
            emit({"check": check_id, "status": "skip", "detail": str(reason)})
        except Exception as error:  # noqa: BLE001 - every failure is a result
            emit({"check": check_id, "status": "fail", "detail": f"{type(error).__name__}: {error}"})

    async def call(self, name: str, args: dict[str, Any] | None = None, **kwargs: Any) -> types.CallToolResult:
        return await self.client.call_tool(name, args, **kwargs)

    async def run_everything(self) -> None:
        c = self.client

        async def ping() -> str:
            await c.send_ping()
            return "ok"

        await self.check("ping", ping, only="handshake")

        async def discover() -> str:
            # discover() returns the result a pinned mode synthesized; send the request.
            raw = await c.session.send_discover(c.protocol_version)
            result = types.DiscoverResult.model_validate(raw)
            require(bool(result.supported_versions), "no supported_versions")
            return ",".join(result.supported_versions or [])

        await self.check("discover", discover, only="stateless")

        async def tools_list() -> str:
            names = {t.name for t in (await c.list_tools()).tools}
            core = [
                "test_simple_text", "test_image_content", "test_audio_content", "test_embedded_resource",
                "test_multiple_content_types", "test_tool_with_logging", "test_tool_with_progress",
                "test_error_handling", "test_sampling", "test_elicitation",
            ]
            missing = [n for n in core if n not in names]
            require(not missing, f"missing {missing}")
            return f"{len(names)} tools"

        await self.check("tools-list", tools_list)

        async def simple_text() -> str:
            r = await self.call("test_simple_text")
            require(not r.is_error and texts(r.content) != "", f"kinds {kinds(r.content)}")
            return texts(r.content)

        await self.check("tool-simple-text", simple_text)

        for check_id, name, kind in [
            ("tool-image", "test_image_content", "image"),
            ("tool-audio", "test_audio_content", "audio"),
            ("tool-embedded-resource", "test_embedded_resource", "resource"),
        ]:

            async def single(name: str = name, kind: str = kind) -> str:
                r = await self.call(name)
                require(kinds(r.content) == [kind], f"kinds {kinds(r.content)}")
                item = r.content[0]
                if isinstance(item, (types.ImageContent, types.AudioContent)):
                    return f"{item.mime_type}, {len(item.data)} b64"
                if isinstance(item, types.EmbeddedResource):
                    return str(item.resource.uri)
                return kind

            await self.check(check_id, single)

        async def multiple() -> str:
            found = kinds((await self.call("test_multiple_content_types")).content)
            require({"text", "image", "resource"} <= set(found), f"kinds {found}")
            return ",".join(found)

        await self.check("tool-multiple-content", multiple)

        async def error() -> str:
            r = await self.call("test_error_handling")
            require(bool(r.is_error), f"isError {r.is_error}")
            return texts(r.content)

        await self.check("tool-error", error)

        async def set_level() -> str:
            await c.set_logging_level("debug")
            return "debug"

        await self.check("logging-set-level", set_level, only="handshake")

        async def logging() -> str:
            before = counts["logs"]
            await self.call("test_tool_with_logging")
            await asyncio.sleep(0.3)
            received = counts["logs"] - before
            require(received > 0, "no notifications/message")
            return f"{received} log notifications"

        await self.check("tool-logging", logging)

        async def progress() -> str:
            before = counts["progress"]
            await self.call("test_tool_with_progress", progress_callback=on_progress)
            await asyncio.sleep(0.3)
            received = counts["progress"] - before
            require(received > 0, "no notifications/progress")
            return f"{received} progress notifications"

        await self.check("tool-progress", progress)

        async def sampling() -> str:
            r = await self.call("test_sampling", {"prompt": "Say hello"})
            require(not r.is_error and "interop sampling reply" in texts(r.content), texts(r.content))
            return texts(r.content)

        await self.check("tool-sampling", sampling, only="handshake")

        async def elicitation() -> str:
            r = await self.call("test_elicitation", {"message": "Who are you?"})
            require(not r.is_error and "accept" in texts(r.content), texts(r.content))
            return texts(r.content)

        await self.check("tool-elicitation", elicitation, only="handshake")

        for check_id, name, handler in [
            ("mrtr-elicitation", "test_input_required_result_elicitation", "elicitation"),
            ("mrtr-sampling", "test_input_required_result_sampling", "sampling"),
            ("mrtr-list-roots", "test_input_required_result_list_roots", "roots"),
            ("mrtr-multiple-inputs", "test_input_required_result_multiple_inputs", "elicitation"),
            ("mrtr-multi-round", "test_input_required_result_multi_round", "elicitation"),
        ]:

            async def mrtr(name: str = name, handler: str = handler) -> str:
                before = counts[handler]
                r = await self.call(name)
                require(not r.is_error, f"isError: {texts(r.content)}")
                calls = counts[handler] - before
                require(calls > 0, "handler not called")
                return f"{calls} handler calls: {texts(r.content)[:80]}"

            await self.check(check_id, mrtr, only="stateless")

        async def unknown_tool() -> str:
            try:
                r = await self.call("interop_no_such_tool")
            except MCPError as e:
                # Only the spec's unknown-tool code: a crashed server or an
                # HTTP 5xx also reaches the client as an MCPError.
                if e.code != -32602:
                    raise
                return f"JSON-RPC error {e.code}"
            require(bool(r.is_error), "accepted")
            return "isError result"

        await self.check("unknown-tool", unknown_tool)

        async def resources_list() -> str:
            uris = sorted(str(r.uri) for r in (await c.list_resources()).resources)
            missing = [u for u in ("test://static-text", "test://static-binary") if u not in uris]
            require(not missing, f"missing {missing}; have {uris}")
            return ",".join(uris)

        await self.check("resources-list", resources_list)

        async def static_text() -> str:
            contents = (await c.read_resource("test://static-text")).contents
            require(bool(contents) and bool(getattr(contents[0], "text", "")), "no text")
            return contents[0].text

        await self.check("resource-static-text", static_text)

        async def static_binary() -> str:
            contents = (await c.read_resource("test://static-binary")).contents
            require(bool(contents) and bool(getattr(contents[0], "blob", "")), "no blob")
            return f"{contents[0].mime_type}, {len(contents[0].blob)} b64"

        await self.check("resource-static-binary", static_binary)

        async def templates_list() -> str:
            templates = [t.uri_template for t in (await c.list_resource_templates()).resource_templates]
            require("test://template/{id}/data" in templates, f"have {templates}")
            return ",".join(templates)

        await self.check("resource-templates-list", templates_list)

        async def template_read() -> str:
            contents = (await c.read_resource("test://template/42/data")).contents
            text = getattr(contents[0], "text", "") if contents else ""
            require("42" in text, f"text {text!r}")
            return text

        await self.check("resource-template-read", template_read)

        async def unknown_resource() -> str:
            try:
                await c.read_resource("test://interop-missing")
            except MCPError as e:
                # Resource not found: -32602 at 2026-07-28, -32002 at 2025-11-25.
                if e.code not in (-32602, -32002):
                    raise
                return f"JSON-RPC error {e.code}"
            raise CheckFailed("accepted")

        await self.check("unknown-resource", unknown_resource)

        async def prompts_list() -> str:
            names = {p.name for p in (await c.list_prompts()).prompts}
            core = [
                "test_simple_prompt", "test_prompt_with_arguments", "test_prompt_with_embedded_resource",
                "test_prompt_with_image",
            ]
            missing = [n for n in core if n not in names]
            require(not missing, f"missing {missing}")
            return f"{len(names)} prompts"

        await self.check("prompts-list", prompts_list)

        async def prompt_simple() -> str:
            messages = (await c.get_prompt("test_simple_prompt")).messages
            require(bool(messages), "no messages")
            return f"{len(messages)} messages"

        await self.check("prompt-simple", prompt_simple)

        async def prompt_arguments() -> str:
            messages = (await c.get_prompt("test_prompt_with_arguments", {"arg1": "alpha", "arg2": "beta"})).messages
            text = " ".join(m.content.text for m in messages if isinstance(m.content, types.TextContent))
            require("alpha" in text and "beta" in text, text)
            return text

        await self.check("prompt-arguments", prompt_arguments)

        async def prompt_resource() -> str:
            messages = (
                await c.get_prompt("test_prompt_with_embedded_resource", {"resourceUri": "test://static-text"})
            ).messages
            uris = [str(m.content.resource.uri) for m in messages if isinstance(m.content, types.EmbeddedResource)]
            require(bool(uris), "no embedded resource")
            return ",".join(uris)

        await self.check("prompt-embedded-resource", prompt_resource)

        async def prompt_image() -> str:
            messages = (await c.get_prompt("test_prompt_with_image")).messages
            images = [m for m in messages if isinstance(m.content, types.ImageContent)]
            require(bool(images), "no image")
            return f"{len(images)} images"

        await self.check("prompt-image", prompt_image)

    async def run_advanced(self, watched_updates: bool) -> None:
        c = self.client
        caps = c.server_capabilities
        if self.era == "stateless":
            # A pinned mode adopts a synthesized discover result with no
            # capabilities (and discover() returns it); probe the server.
            raw = await c.session.send_discover(c.protocol_version)
            caps = types.DiscoverResult.model_validate(raw).capabilities

        async def tools_list() -> str:
            return f"{len((await c.list_tools()).tools)} tools"

        await self.check("tools-list", tools_list)

        async def concurrent_calls() -> str:
            names = [f"interop-c{i}" for i in range(8)]
            before = Counter(tokens)
            errors: list[str] = []

            async def progress_call(token: str) -> None:
                r = await self.call("test_tool_with_progress", progress_callback=progress_for(token))
                if r.is_error:
                    errors.append(f"{token}: isError")

            async def text_call() -> None:
                if not texts((await self.call("test_simple_text")).content):
                    errors.append("simple text: empty")

            async def image_call() -> None:
                found = kinds((await self.call("test_image_content")).content)
                if found != ["image"]:
                    errors.append(f"image: {found}")

            async with anyio.create_task_group() as group:
                for token in names:
                    group.start_soon(progress_call, token)
                for _ in range(4):
                    group.start_soon(text_call)
                    group.start_soon(image_call)
            require(not errors, "; ".join(errors))
            await asyncio.sleep(0.3)
            silent = [t for t in names if tokens[t] == before[t]]
            require(not silent, f"no progress for {silent}")
            # No check for progress on unknown tokens (the Swift and Go drivers have one):
            # the SDK routes progress to the callback of its request, so the token is never seen.
            return f"16 calls, progress kept apart for {len(names)} tokens"

        await self.check("concurrent-calls", concurrent_calls)

        async def concurrent_input() -> str:
            if self.era == "handshake":
                pair = [("test_sampling", {"prompt": "Say hello"}), ("test_elicitation", {"message": "Who are you?"})]
            else:
                pair = [("test_input_required_result_sampling", None), ("test_input_required_result_elicitation", None)]
            calls = pair * 4
            before = counts["sampling"] + counts["elicitation"]
            errors: list[str] = []

            async def one(name: str, args: dict[str, Any] | None) -> None:
                r = await self.call(name, args)
                if r.is_error:
                    errors.append(f"{name}: {texts(r.content)}")

            async with anyio.create_task_group() as group:
                for name, args in calls:
                    group.start_soon(one, name, args)
            require(not errors, "; ".join(errors))
            handled = counts["sampling"] + counts["elicitation"] - before
            require(handled >= len(calls), f"{handled} handler calls for {len(calls)} tools")
            return f"{len(calls)} calls, {handled} handler calls"

        await self.check("concurrent-input", concurrent_input)

        async def cancel_then_continue() -> str:
            outcome = "cancelled"
            with anyio.move_on_after(0.02):
                await self.call("test_tool_with_progress", progress_callback=progress_for("interop-cancel"))
                outcome = "completed before the cancel"
            require(bool(texts((await self.call("test_simple_text")).content)), "the next call failed")
            return f"{outcome}; next call answered"

        await self.check("cancel-then-continue", cancel_then_continue)

        for check_id, tool, counter, declared, what in [
            ("tools-list-changed", "test_trigger_tool_change", "tools-changed",
             bool(caps.tools and caps.tools.list_changed), "tools"),
            ("prompts-list-changed", "test_trigger_prompt_change", "prompts-changed",
             bool(caps.prompts and caps.prompts.list_changed), "prompts"),
        ]:

            async def list_changed(tool: str = tool, counter: str = counter, declared: bool = declared,
                                   what: str = what) -> str:
                if not declared:
                    raise Skip(f"the server does not declare {what}.listChanged")
                before = counts[counter]
                await self.call(tool)
                require(await wait_for(3, lambda: counts[counter] > before), "no list_changed notification within 3 s")
                return "notified"

            await self.check(check_id, list_changed)

        async def resource_subscribe() -> str:
            if not (caps.resources and caps.resources.subscribe):
                raise Skip("the server does not declare resources.subscribe")
            if self.era == "handshake":
                await c.subscribe_resource("test://watched-resource")
                return "subscribed"
            require(self.listening, "subscriptions/listen did not open")
            return "subscribed via subscriptions/listen"

        await self.check("resource-subscribe", resource_subscribe)

        async def resource_updated() -> str:
            if not watched_updates:
                raise Skip("the server never updates test://watched-resource")
            require(await wait_for(8, lambda: counts["resource-updated"] > 0),
                    "no notifications/resources/updated within 8 s")
            return f"{counts['resource-updated']} updates"

        await self.check("resource-updated", resource_updated)

        async def reconnection() -> str:
            if not self.is_http:
                raise Skip("HTTP only")
            text = texts((await self.call("test_reconnection")).content)
            require("Reconnection test completed" in text, repr(text))
            return text

        await self.check("reconnection", reconnection)

        for check_id, region in [("mcp-param-header", "eu-west-1"), ("mcp-param-header-unicode", "Zürich 東京")]:

            async def header(region: str = region) -> str:
                if not self.is_http:
                    raise Skip("HTTP only")
                # Header bindings come from the tool list; list_changed above invalidated it.
                await self.client.list_tools()
                r = await self.call("test_x_mcp_header", {"region": region})
                require(not r.is_error and region in texts(r.content), repr(texts(r.content)))
                return texts(r.content)

            await self.check(check_id, header, only="stateless")

        async def streaming_elicitation() -> str:
            r = await self.call("test_streaming_elicitation")
            require(not r.is_error, repr(texts(r.content)))
            return texts(r.content)

        await self.check("streaming-elicitation", streaming_elicitation)

    listening = False

    async def run_tool(self, tool: str, args: dict[str, Any], expect: str) -> None:
        async def tools_list() -> str:
            names = [t.name for t in (await self.client.list_tools()).tools]
            require(tool in names, f"have {names}")
            return ",".join(names)

        await self.check("tools-list", tools_list)

        async def tool_call() -> str:
            r = await self.call(tool, args)
            require(not r.is_error and expect in texts(r.content), texts(r.content))
            return texts(r.content)

        await self.check("tool-call", tool_call)


async def run_advanced(battery: Battery, watched_updates: bool) -> None:
    """At 2026-07-28, list changes and resource updates arrive on a subscriptions/listen stream."""
    if battery.era == "handshake":
        await battery.run_advanced(watched_updates)
        return
    async with AsyncExitStack() as stack:
        try:
            with anyio.fail_after(battery.timeout):
                sub = await stack.enter_async_context(battery.client.listen(
                    tools_list_changed=True, prompts_list_changed=True,
                    resource_subscriptions=["test://watched-resource"],
                ))
            battery.listening = True
        except Exception as error:  # noqa: BLE001
            print(f"listen: {type(error).__name__}: {error}", file=sys.stderr)
            await battery.run_advanced(watched_updates)
            return
        async with anyio.create_task_group() as group:

            async def drain() -> None:
                async for _ in sub:
                    pass  # on_message counts the teed notifications

            group.start_soon(drain)
            await battery.run_advanced(watched_updates)
            group.cancel_scope.cancel()


# The tasks checks of an SDK with a tasks runtime; the Python SDK has none.
TASK_RUNTIME_CHECKS = [
    "task-create", "task-input", "task-partial-input", "task-tool-error", "task-protocol-error", "task-cancel",
    "task-mrtr-composition", "task-list",
]


async def run_tasks(battery: Battery) -> None:
    """Checks that a client that does not use tasks can call the task tools."""
    for check_id in TASK_RUNTIME_CHECKS:
        emit({"check": check_id, "status": "skip", "detail": "the Python SDK has no tasks runtime"})

    async def inline() -> str:
        r = await battery.call("slow_compute", {"seconds": 0, "label": "interop"})
        require(not r.is_error and "Computed interop" in texts(r.content), f"unexpected result: {texts(r.content)}")
        return texts(r.content)

    await battery.check("task-tool-inline", inline)

    async def refused() -> str:
        expected = -32021 if battery.era == "stateless" else -32601
        try:
            r = await battery.call("failing_job")
        except MCPError as e:
            require(e.code == expected, f"code {e.code}, expected {expected}")
            return f"JSON-RPC error {e.code}"
        raise AssertionError(f"returned {texts(r.content)}")

    await battery.check("task-required-refused", refused)


async def run_session(battery: Battery, options: argparse.Namespace, target: Any, mode: str) -> None:
    async def before() -> str:
        return texts((await battery.call("test_simple_text")).content)

    await battery.check("session-before", before)
    try:
        await pause(options.pause_file)
    except Exception as error:  # noqa: BLE001
        emit({"check": "session-expired", "status": "fail", "detail": str(error)})
        return

    async def expired() -> str:
        try:
            with anyio.fail_after(10):
                r = await battery.call("test_simple_text")
        except TimeoutError:
            raise CheckFailed("timed out after 10 s") from None
        except Exception as error:  # noqa: BLE001 - a prompt error is the expected outcome
            text = f"{type(error).__name__}: {error}"
            if not LOST_SESSION.search(text):
                raise CheckFailed(f"unexpected error: {text}") from None
            return f"error: {text}"
        return f"recovered: {texts(r.content)}"

    await battery.check("session-expired", expired)

    async def reconnect() -> str:
        async with make_client(target, mode) as fresh:
            return texts((await fresh.call_tool("test_simple_text")).content)

    await battery.check("session-reconnect", reconnect)


async def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url")
    parser.add_argument("--era", default="auto", choices=["auto", "handshake", "stateless"])
    parser.add_argument("--profile", default="everything",
                        choices=["everything", "advanced", "connect", "session", "tasks", "tool"])
    parser.add_argument("--expect-era", default="", choices=["", "handshake", "stateless", "unsupported"])
    parser.add_argument("--watched-updates", action="store_true")
    parser.add_argument("--pause-file", default="")
    parser.add_argument("--tool", default="")
    parser.add_argument("--args", default="{}")
    parser.add_argument("--expect", default="")
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--stdio", nargs=argparse.REMAINDER)
    options = parser.parse_args()

    if options.url:
        target: Any = options.url
    elif options.stdio:
        target = StdioServerParameters(command=options.stdio[0], args=options.stdio[1:])
    else:
        emit({"check": "arguments", "status": "fail", "detail": "pass --url or --stdio"})
        return 2

    mode = {"handshake": "legacy", "stateless": "2026-07-28"}.get(options.era, "auto")
    client = make_client(target, mode)
    connected = False
    finished = False  # the profile's checks ran to the end
    try:
        async with client:
            connected = True
            version = client.protocol_version
            era = "stateless" if version >= "2026-07-28" else "handshake"
            info = client.server_info
            if info is None and client.session.discover_result is not None:
                # 2026-07-28: serverInfo travels in the result's `_meta`.
                meta = client.session.discover_result.meta or {}
                raw = meta.get("io.modelcontextprotocol/serverInfo")
                info = types.Implementation.model_validate(raw) if raw else None
            emit({"meta": {
                "client": "python", "era": era, "protocolVersion": version,
                "server": f"{info.name} {info.version}" if info else "?",
            }})
            if options.expect_era == "unsupported":
                # The client must not speak 2026-07-28 to a server without it: an error at
                # connect (below), a fallback to the handshake, or a rejected first request.
                if era == "handshake":
                    emit({"check": "connect", "status": "pass", "detail": f"fell back to {version} (handshake)"})
                    finished = True
                    return 0
                try:
                    with anyio.fail_after(options.timeout):
                        await client.list_tools()
                    emit({"check": "connect", "status": "fail", "detail": f"{version} accepted, expected unsupported"})
                except Exception as error:  # noqa: BLE001
                    text = f"{type(error).__name__}: {error}"
                    ok = rejects_protocol_version(text)
                    emit({"check": "connect", "status": "pass" if ok else "fail",
                          "detail": f"first request rejected: {text}"})
                finished = True
                return 0
            expected = options.expect_era or ("" if options.era == "auto" else options.era)
            detail = f"{version} ({era})" + (f", expected {expected}" if expected else "")
            ok = not expected or expected == era
            emit({"check": "connect", "status": "pass" if ok else "fail", "detail": detail})
            battery = Battery(client, era, options.timeout, is_http=bool(options.url))
            if options.profile == "advanced":
                await run_advanced(battery, options.watched_updates)
            elif options.profile == "connect":

                async def tools_list() -> str:
                    return f"{len((await client.list_tools()).tools)} tools"

                await battery.check("tools-list", tools_list)
            elif options.profile == "session":
                await run_session(battery, options, target, mode)
            elif options.profile == "tasks":
                await run_tasks(battery)
            elif options.profile == "tool":
                await battery.run_tool(options.tool, json.loads(options.args), options.expect)
            else:
                await battery.run_everything()
            finished = True
    except Exception as error:  # noqa: BLE001
        if finished:  # shutdown noise is not a result
            print(f"shutdown: {type(error).__name__}: {error}", file=sys.stderr)
        elif connected:  # the checks stopped early: a result
            cause: BaseException = error
            while isinstance(cause, BaseExceptionGroup) and cause.exceptions:
                cause = cause.exceptions[0]  # a task group's error, not the group
            emit({"check": "battery", "status": "fail", "detail": f"{type(cause).__name__}: {cause}"})
            return 1
        else:
            emit({"meta": {"client": "python", "era": options.era}})
            detail = f"{type(error).__name__}: {error}"
            if options.expect_era == "unsupported":
                ok = rejects_protocol_version(detail)
                emit({"check": "connect", "status": "pass" if ok else "fail", "detail": detail})
                return 0
            emit({"check": "connect", "status": "fail", "detail": detail})
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(anyio.run(main))
