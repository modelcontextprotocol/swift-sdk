// ts-interop-client: runs the interop `tasks` profile (interop/README.md) on
// the TypeScript SDK, and prints one JSON object per line: a `meta` line,
// then one line per check. The SDK speaks 2025-11-25 only.
//
//   node client.mjs --profile tasks --url http://127.0.0.1:3101/mcp [--era handshake|auto]
//   node client.mjs --profile tasks --stdio path/to/server [args...]

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import {
    CallToolResultSchema,
    CreateTaskResultSchema,
    ElicitRequestSchema,
    McpError
} from '@modelcontextprotocol/sdk/types.js';

function emit(object) {
    process.stdout.write(JSON.stringify(object) + '\n');
}

function parse(argv) {
    const options = { era: 'auto', profile: 'tasks', timeout: 20, stdio: [] };
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        const value = () => argv[++i];
        if (arg === '--url') options.url = value();
        else if (arg === '--era') options.era = value();
        else if (arg === '--profile') options.profile = value();
        else if (arg === '--timeout') options.timeout = Number(value());
        else if (arg === '--stdio') {
            options.stdio = argv.slice(i + 1);
            break;
        } else throw new Error(`unknown argument ${arg}`);
    }
    if (!options.url && options.stdio.length === 0) throw new Error('pass --url or --stdio');
    return options;
}

const texts = content => (content ?? []).filter(c => c.type === 'text').map(c => c.text).join(' ');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function withTimeout(seconds, body) {
    let timer;
    return Promise.race([
        body().finally(() => clearTimeout(timer)),
        new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error(`timed out after ${seconds} s`)), seconds * 1000);
        })
    ]);
}

class Skip extends Error {}

function require(condition, message) {
    if (!condition) throw new Error(message);
}

async function main() {
    let options;
    try {
        options = parse(process.argv.slice(2));
    } catch (error) {
        emit({ check: 'arguments', status: 'fail', detail: String(error.message ?? error) });
        return 2;
    }
    const counts = { elicitation: 0 };
    const client = new Client(
        { name: 'ts-interop-client', version: '1.0.0' },
        { capabilities: { elicitation: { form: {} } } }
    );
    client.setRequestHandler(ElicitRequestSchema, async request => {
        counts.elicitation += 1;
        const content = {};
        for (const [name, property] of Object.entries(request.params.requestedSchema?.properties ?? {})) {
            content[name] = property.type === 'boolean' ? true : property.type === 'number' ? 1 : 'interop';
        }
        return { action: 'accept', content };
    });
    const transport = options.url
        ? new StreamableHTTPClientTransport(new URL(options.url))
        : new StdioClientTransport({ command: options.stdio[0], args: options.stdio.slice(1), stderr: 'ignore' });
    try {
        await withTimeout(options.timeout, () => client.connect(transport));
    } catch (error) {
        emit({ meta: { client: 'ts', era: options.era } });
        emit({ check: 'connect', status: 'fail', detail: String(error) });
        return 1;
    }
    const version = transport.protocolVersion ?? client.getNegotiatedProtocolVersion?.() ?? '2025-11-25';
    const server = client.getServerVersion();
    emit({ meta: { client: 'ts', era: 'handshake', protocolVersion: version, server: `${server?.name ?? '?'} ${server?.version ?? ''}` } });
    const expected = options.era === 'auto' ? undefined : options.era;
    emit({
        check: 'connect',
        status: !expected || expected === 'handshake' ? 'pass' : 'fail',
        detail: `${version} (handshake)` + (expected ? `, expected ${expected}` : '')
    });
    if (options.profile !== 'tasks') {
        emit({ check: 'profile', status: 'fail', detail: `the TypeScript driver runs only the tasks profile` });
        await client.close();
        return 2;
    }

    const tools = new Set((await client.listTools()).tools.map(tool => tool.name));
    async function check(id, body) {
        try {
            const detail = await withTimeout(options.timeout, body);
            emit({ check: id, status: 'pass', detail });
        } catch (error) {
            if (error instanceof Skip) emit({ check: id, status: 'skip', detail: error.message });
            else emit({ check: id, status: 'fail', detail: String(error.message ?? error) });
        }
    }
    function needs(name) {
        if (!tools.has(name)) throw new Skip(`the server has no ${name}`);
    }
    // Creates a task for a tool call and returns it.
    async function create(name, args) {
        needs(name);
        const created = await client.request(
            { method: 'tools/call', params: { name, arguments: args, task: { ttl: 60000 } } },
            CreateTaskResultSchema
        );
        return created.task;
    }
    async function terminal(taskId) {
        for (let i = 0; i < 200; i++) {
            const task = await client.experimental.tasks.getTask(taskId);
            if (['completed', 'failed', 'cancelled'].includes(task.status)) return task;
            await sleep(Math.min(task.pollInterval ?? 200, 500));
        }
        throw new Error(`task ${taskId} did not finish`);
    }
    // Drives a tool call as a task with the SDK's stream and returns the result.
    async function stream(name, args) {
        needs(name);
        let result;
        for await (const message of client.experimental.tasks.callToolStream(
            { name, arguments: args },
            CallToolResultSchema,
            { task: { ttl: 60000 } }
        )) {
            if (message.type === 'result') result = message.result;
            else if (message.type === 'error') throw message.error;
        }
        require(result, 'no result');
        return result;
    }
    const created = [];

    await check('task-create', async () => {
        const task = await create('slow_compute', { seconds: 1, label: 'interop' });
        created.push(task.taskId);
        require(task.status === 'working', `status ${task.status}`);
        await terminal(task.taskId);
        const result = await client.experimental.tasks.getTaskResult(task.taskId, CallToolResultSchema);
        require(texts(result.content).includes('Computed interop'), texts(result.content));
        require(result._meta?.['io.modelcontextprotocol/related-task']?.taskId === task.taskId, 'no related-task');
        return `working -> ${texts(result.content)}`;
    });
    await check('task-input', async () => {
        const before = counts.elicitation;
        const result = await stream('confirm_delete', { filename: 'interop.txt' });
        require(counts.elicitation > before, 'elicitation handler not called');
        require(texts(result.content) === 'Deleted interop.txt', texts(result.content));
        return texts(result.content);
    });
    await check('task-partial-input', async () => {
        const before = counts.elicitation;
        const result = await stream('multi_input', {});
        require(counts.elicitation - before === 2, `${counts.elicitation - before} elicitation calls`);
        return texts(result.content);
    });
    await check('task-tool-error', async () => {
        const task = await create('failing_job', {});
        created.push(task.taskId);
        const done = await terminal(task.taskId);
        require(done.status === 'failed', `status ${done.status}`);
        const result = await client.experimental.tasks.getTaskResult(task.taskId, CallToolResultSchema);
        require(result.isError === true, `isError ${result.isError}`);
        return texts(result.content);
    });
    await check('task-protocol-error', async () => {
        const task = await create('protocol_error_job', {});
        await terminal(task.taskId);
        try {
            await client.experimental.tasks.getTaskResult(task.taskId, CallToolResultSchema);
        } catch (error) {
            require(error instanceof McpError && error.code === -32603, `error ${error}`);
            return `JSON-RPC error ${error.code}`;
        }
        throw new Error('tasks/result returned a result');
    });
    await check('task-cancel', async () => {
        const task = await create('slow_compute', { seconds: 60, label: 'interop-cancel' });
        const cancelled = await client.experimental.tasks.cancelTask(task.taskId);
        require(cancelled.status === 'cancelled', `status ${cancelled.status}`);
        require((await client.experimental.tasks.getTask(task.taskId)).status === 'cancelled', 'not cancelled');
        try {
            await client.experimental.tasks.cancelTask(task.taskId);
        } catch (error) {
            require(error instanceof McpError && error.code === -32602, `error ${error}`);
            return 'cancelled; cancelling again: -32602';
        }
        throw new Error('a cancelled task was cancelled again');
    });
    await check('task-mrtr-composition', async () => {
        throw new Skip('2026-07-28 only');
    });
    await check('task-list', async () => {
        if (!client.getServerCapabilities()?.tasks?.list) throw new Skip('the server does not declare tasks.list');
        const listed = new Set((await client.experimental.tasks.listTasks()).tasks.map(task => task.taskId));
        const missing = created.filter(id => !listed.has(id));
        require(missing.length === 0, `missing ${missing}`);
        return `${listed.size} tasks`;
    });
    await check('task-tool-inline', async () => {
        const result = await client.callTool({ name: 'slow_compute', arguments: { seconds: 0, label: 'interop' } });
        require(!result.isError && texts(result.content).includes('Computed interop'), texts(result.content));
        return texts(result.content);
    });
    await check('task-required-refused', async () => {
        // A raw request: callTool refuses a required tool before sending it.
        let result;
        try {
            result = await client.request(
                { method: 'tools/call', params: { name: 'failing_job', arguments: {} } },
                CallToolResultSchema
            );
        } catch (error) {
            require(error instanceof McpError && error.code === -32601, `error ${error}`);
            return `JSON-RPC error ${error.code}`;
        }
        throw new Error(`returned ${texts(result.content)}`);
    });
    await client.close();
    return 0;
}

process.exit(await main());
