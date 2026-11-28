// ts-interop-server: an MCP server on the TypeScript SDK's task runtime
// (SEP-1686, protocol 2025-11-25) with the task tools of the interop
// `tasks` profile, and the view and tools of the `apps` profile (SEP-1865)
// on the ext-apps server helpers (interop/README.md).
//
//   node server.mjs --port 3401    Streamable HTTP at http://127.0.0.1:3401/mcp
//   node server.mjs --stdio
//
// The tools match the Swift everything-server's: slow_compute, failing_job,
// confirm_delete and multi_input run as tasks; greet never does. The SDK
// keeps a failed task's result, not a JSON-RPC error, so there is no
// protocol_error_job, and 2025-11-25 has no input_required results, so no
// test_tool_with_task.
//
// The apps fixture matches the Swift everything-server's (Apps.swift): the
// view ui://interop/weather.html, show_weather, which renders in it, and
// refresh_weather, for the view only. registerAppTool also writes the
// deprecated flat key _meta["ui/resourceUri"].

import { randomUUID } from 'node:crypto';
import * as z from 'zod/v4';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { createMcpExpressApp } from '@modelcontextprotocol/sdk/server/express.js';
import { ElicitResultSchema, isInitializeRequest } from '@modelcontextprotocol/sdk/types.js';
import { InMemoryTaskStore, InMemoryTaskMessageQueue } from '@modelcontextprotocol/sdk/experimental/tasks';
import {
    getUiCapability,
    registerAppResource,
    registerAppTool,
    RESOURCE_MIME_TYPE
} from '@modelcontextprotocol/ext-apps/server';

const taskStore = new InMemoryTaskStore();
const taskMessageQueue = new InMemoryTaskMessageQueue();

const text = (value, isError = false) => ({ content: [{ type: 'text', text: value }], ...(isError ? { isError } : {}) });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function makeServer() {
    const server = new McpServer(
        { name: 'ts-interop-server', version: '1.32.2' },
        {
            capabilities: { tasks: { list: {}, cancel: {}, requests: { tools: { call: {} } } } },
            taskStore,
            taskMessageQueue
        }
    );

    // Asks the client through the task's message queue, delivered on tasks/result.
    async function elicit(store, taskId, message, requestedSchema) {
        await store.updateTaskStatus(taskId, 'input_required');
        try {
            return await server.server.request(
                { method: 'elicitation/create', params: { mode: 'form', message, requestedSchema } },
                ElicitResultSchema,
                { relatedTask: { taskId } }
            );
        } finally {
            const task = await store.getTask(taskId);
            if (task && task.status === 'input_required') await store.updateTaskStatus(taskId, 'working');
        }
    }

    // A tool whose work runs as a task; `work` returns the tool result.
    function taskTool(name, description, taskSupport, inputSchema, work) {
        server.experimental.tasks.registerToolTask(
            name,
            { description, inputSchema, execution: { taskSupport } },
            {
                async createTask(args, { taskStore: store, taskRequestedTtl }) {
                    const task = await store.createTask({ ttl: taskRequestedTtl, pollInterval: 200 });
                    (async () => {
                        let result;
                        try {
                            result = await work(args, store, task.taskId);
                        } catch (error) {
                            result = text(`The job crashed: ${error}`, true);
                        }
                        try {
                            await store.storeTaskResult(task.taskId, result.isError ? 'failed' : 'completed', result);
                        } catch {
                            // Cancelled meanwhile: the task stays cancelled.
                        }
                    })();
                    return { task };
                },
                async getTask(_args, { taskId, taskStore: store }) {
                    return await store.getTask(taskId);
                },
                async getTaskResult(_args, { taskId, taskStore: store }) {
                    return await store.getTaskResult(taskId);
                }
            }
        );
    }

    server.registerTool(
        'greet',
        { description: 'Says hello; never a task', inputSchema: { name: z.string().optional() } },
        async ({ name }) => text(`Hello, ${name ?? 'World'}!`)
    );
    taskTool(
        'slow_compute',
        'Sleeps for `seconds`, then answers',
        'optional',
        { seconds: z.number().optional(), label: z.string().optional() },
        async ({ seconds = 0, label = 'task' }) => {
            if (seconds > 0) await sleep(seconds * 1000);
            return text(`Computed ${label} in ${seconds}s`);
        }
    );
    taskTool('failing_job', 'Reports a tool error after a second', 'required', {}, async () => {
        await sleep(1000);
        return text('The job failed', true);
    });
    const confirmSchema = { type: 'object', properties: { confirm: { type: 'boolean' } }, required: ['confirm'] };
    taskTool(
        'confirm_delete',
        'Asks to confirm deleting `filename`',
        'optional',
        { filename: z.string().optional() },
        async ({ filename = 'the file' }, store, taskId) => {
            const answer = await elicit(store, taskId, `Delete ${filename}?`, confirmSchema);
            const confirmed = answer.action === 'accept' && answer.content?.confirm === true;
            return text(confirmed ? `Deleted ${filename}` : `Kept ${filename}`);
        }
    );
    const nameSchema = { type: 'object', properties: { name: { type: 'string' } }, required: ['name'] };
    taskTool('multi_input', 'Asks two questions at once', 'optional', {}, async (_args, store, taskId) => {
        const answers = await Promise.all([
            elicit(store, taskId, 'First name?', nameSchema),
            elicit(store, taskId, 'Second name?', nameSchema)
        ]);
        return text(`Received ${answers.map(a => a.content?.name ?? '?').join(' and ')}`);
    });

    const viewUri = 'ui://interop/weather.html';
    const viewMeta = { ui: { csp: { connectDomains: ['https://api.example.com'] }, prefersBorder: true } };
    registerAppResource(server, 'weather-view', viewUri, { description: 'The weather view', _meta: viewMeta }, async () => ({
        contents: [
            {
                uri: viewUri,
                mimeType: RESOURCE_MIME_TYPE,
                text: '<!DOCTYPE html><html><body>interop weather view</body></html>',
                _meta: viewMeta
            }
        ]
    }));
    registerAppTool(
        server,
        'show_weather',
        {
            description: 'Shows the weather in a view',
            inputSchema: { city: z.string().optional() },
            _meta: { ui: { resourceUri: viewUri } }
        },
        async ({ city }) => {
            const declared = getUiCapability(server.server.getClientCapabilities())?.mimeTypes?.includes(RESOURCE_MIME_TYPE);
            return text(`Weather in ${city ?? 'Paris'}: sunny (view ${declared ? 'declared' : 'not declared'})`);
        }
    );
    registerAppTool(
        server,
        'refresh_weather',
        {
            description: 'Refreshes the weather view; for the view only',
            inputSchema: {},
            _meta: { ui: { resourceUri: viewUri, visibility: ['app'] } }
        },
        async () => text('Refreshed')
    );
    return server;
}

const args = process.argv.slice(2);
if (args.includes('--stdio')) {
    await makeServer().connect(new StdioServerTransport());
} else {
    const port = Number(args[args.indexOf('--port') + 1] || 3401);
    const app = createMcpExpressApp();
    const sessions = new Map();
    app.post('/mcp', async (req, res) => {
        const sessionId = req.headers['mcp-session-id'];
        let transport = sessionId ? sessions.get(sessionId) : undefined;
        if (!transport) {
            if (sessionId || !isInitializeRequest(req.body)) {
                res.status(sessionId ? 404 : 400).json({
                    jsonrpc: '2.0',
                    error: { code: -32000, message: sessionId ? 'Session not found' : 'No session' },
                    id: null
                });
                return;
            }
            transport = new StreamableHTTPServerTransport({
                sessionIdGenerator: () => randomUUID(),
                onsessioninitialized: id => sessions.set(id, transport)
            });
            transport.onclose = () => transport.sessionId && sessions.delete(transport.sessionId);
            await makeServer().connect(transport);
        }
        await transport.handleRequest(req, res, req.body);
    });
    const stream = async (req, res) => {
        const transport = sessions.get(req.headers['mcp-session-id']);
        if (!transport) {
            res.status(404).end();
            return;
        }
        await transport.handleRequest(req, res);
    };
    app.get('/mcp', stream);
    app.delete('/mcp', stream);
    app.listen(port, '127.0.0.1', () => console.error(`ts-interop-server on http://127.0.0.1:${port}/mcp`));
}
