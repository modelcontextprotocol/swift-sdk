// go-interop-client runs the interop check battery (interop/README.md)
// against an MCP server built with any SDK, using the Go SDK, and prints one
// JSON object per line: a "meta" line, then one line per check.
//
//	go-interop-client -url http://127.0.0.1:3001/mcp [-era handshake|stateless|auto]
//	go-interop-client -era stateless -- path/to/server [args...]
//	go-interop-client -profile tool -tool greet -args '{"name":"Go"}' -expect Go -- path/to/server
//
// Profiles: everything, advanced (concurrency, cancellation, notifications,
// subscriptions, transport edges), connect (-expect-era
// handshake|stateless|unsupported), session (-pause-file; the runner restarts
// the server), tool.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/modelcontextprotocol/go-sdk/jsonrpc"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var (
	urlFlag     = flag.String("url", "", "streamable HTTP endpoint")
	eraFlag     = flag.String("era", "auto", "handshake, stateless or auto")
	profileFlag = flag.String("profile", "everything", "everything, advanced, connect, session, tasks or tool")
	toolFlag    = flag.String("tool", "", "tool profile: tool name")
	argsFlag    = flag.String("args", "{}", "tool profile: JSON arguments")
	expectFlag  = flag.String("expect", "", "tool profile: expected text")
	timeoutFlag = flag.Duration("timeout", 20*time.Second, "per-check timeout")
	expectEra   = flag.String("expect-era", "", "connect profile: handshake, stateless or unsupported")
	watchedFlag = flag.Bool("watched-updates", false, "the server updates test://watched-resource")
	pauseFlag   = flag.String("pause-file", "", "session profile: file the runner resumes through")
)

const logLevelKey = "io.modelcontextprotocol/logLevel"

var counts struct {
	logs, progress, sampling, elicitation         atomic.Int64
	toolsChanged, promptsChanged, resourceUpdated atomic.Int64
}

// tokens counts progress notifications per progress token.
var tokens = struct {
	sync.Mutex
	m map[string]int
}{m: map[string]int{}}

func tokenCounts() map[string]int {
	tokens.Lock()
	defer tokens.Unlock()
	out := make(map[string]int, len(tokens.m))
	for k, v := range tokens.m {
		out[k] = v
	}
	return out
}

// skip marks a check that does not apply to this server.
type skip struct{ reason string }

func (s skip) Error() string { return s.reason }

func emit(v map[string]any) {
	b, _ := json.Marshal(v)
	fmt.Println(string(b))
}

// rejectsProtocolVersion reports whether err rejects the protocol version:
// -32022, or a message that says the protocol version is unsupported (not,
// say, a media type).
func rejectsProtocolVersion(err error) bool {
	text := err.Error()
	lower := strings.ToLower(text)
	return strings.Contains(text, "-32022") ||
		(strings.Contains(lower, "protocol version") &&
			(strings.Contains(lower, "unsupported") || strings.Contains(lower, "not supported")))
}

// lostSession reports whether err says the server no longer knows the session.
func lostSession(err error) bool {
	lower := strings.ToLower(err.Error())
	return strings.Contains(lower, "session not found") || strings.Contains(lower, "session expired") ||
		strings.Contains(lower, "session terminated")
}

type battery struct {
	cs     *mcp.ClientSession
	era    string
	isHTTP bool
}

func (b *battery) check(id, only string, body func(context.Context) (string, error)) {
	if only != "" && only != b.era {
		emit(map[string]any{"check": id, "status": "skip", "detail": only + " only"})
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeoutFlag)
	defer cancel()
	detail, err := body(ctx)
	var s skip
	if errors.As(err, &s) {
		emit(map[string]any{"check": id, "status": "skip", "detail": s.reason})
		return
	}
	if err != nil {
		emit(map[string]any{"check": id, "status": "fail", "detail": err.Error()})
		return
	}
	emit(map[string]any{"check": id, "status": "pass", "detail": detail})
}

// meta asks for log notifications on stateless requests.
func (b *battery) meta() mcp.Meta {
	if b.era == "stateless" {
		return mcp.Meta{logLevelKey: "debug"}
	}
	return nil
}

func (b *battery) call(ctx context.Context, name string, args map[string]any) (*mcp.CallToolResult, error) {
	params := &mcp.CallToolParams{Meta: b.meta(), Name: name, Arguments: args}
	return b.cs.CallTool(ctx, params)
}

// taskRuntimeChecks are the tasks checks of an SDK with a tasks runtime;
// the Go SDK has none.
var taskRuntimeChecks = []string{
	"task-create", "task-input", "task-partial-input", "task-tool-error", "task-protocol-error", "task-cancel",
	"task-mrtr-composition", "task-list",
}

// runTasks checks that a client that does not use tasks can call the task
// tools of the Swift everything-server.
func (b *battery) runTasks() {
	for _, id := range taskRuntimeChecks {
		emit(map[string]any{"check": id, "status": "skip", "detail": "the Go SDK has no tasks runtime"})
	}
	b.check("task-tool-inline", "", func(ctx context.Context) (string, error) {
		res, err := b.call(ctx, "slow_compute", map[string]any{"seconds": 0, "label": "interop"})
		if err != nil {
			return "", err
		}
		if res.IsError || !strings.Contains(texts(res.Content), "Computed interop") {
			return "", fmt.Errorf("unexpected result: %s", texts(res.Content))
		}
		return texts(res.Content), nil
	})
	b.check("task-required-refused", "", func(ctx context.Context) (string, error) {
		expected := int64(-32601)
		if b.era == "stateless" {
			expected = -32021
		}
		res, err := b.call(ctx, "failing_job", nil)
		var rpcErr *jsonrpc.Error
		if errors.As(err, &rpcErr) {
			if int64(rpcErr.Code) != expected {
				return "", fmt.Errorf("code %d, expected %d", rpcErr.Code, expected)
			}
			return fmt.Sprintf("JSON-RPC error %d", rpcErr.Code), nil
		}
		if err != nil {
			return "", err
		}
		return "", fmt.Errorf("returned %s", texts(res.Content))
	})
}

func texts(content []mcp.Content) string {
	var parts []string
	for _, c := range content {
		if t, ok := c.(*mcp.TextContent); ok {
			parts = append(parts, t.Text)
		}
	}
	return strings.Join(parts, " ")
}

func kinds(content []mcp.Content) []string {
	var out []string
	for _, c := range content {
		switch c.(type) {
		case *mcp.TextContent:
			out = append(out, "text")
		case *mcp.ImageContent:
			out = append(out, "image")
		case *mcp.AudioContent:
			out = append(out, "audio")
		case *mcp.EmbeddedResource:
			out = append(out, "resource")
		case *mcp.ResourceLink:
			out = append(out, "resource_link")
		default:
			out = append(out, fmt.Sprintf("%T", c))
		}
	}
	return out
}

func contains(list []string, want ...string) []string {
	have := map[string]bool{}
	for _, s := range list {
		have[s] = true
	}
	var missing []string
	for _, w := range want {
		if !have[w] {
			missing = append(missing, w)
		}
	}
	return missing
}

func settle() { time.Sleep(300 * time.Millisecond) }

func (b *battery) runEverything() {
	b.check("ping", "handshake", func(ctx context.Context) (string, error) {
		return "ok", b.cs.Ping(ctx, nil)
	})
	// v1.8.0 has no ClientSession.Discover; Connect already sent server/discover.
	emit(map[string]any{"check": "discover", "status": "skip", "detail": "no Discover API in this Go SDK release"})
	b.check("tools-list", "", func(ctx context.Context) (string, error) {
		res, err := b.cs.ListTools(ctx, nil)
		if err != nil {
			return "", err
		}
		var names []string
		for _, t := range res.Tools {
			names = append(names, t.Name)
		}
		if m := contains(names, "test_simple_text", "test_image_content", "test_audio_content",
			"test_embedded_resource", "test_multiple_content_types", "test_tool_with_logging",
			"test_tool_with_progress", "test_error_handling", "test_sampling", "test_elicitation"); len(m) > 0 {
			return "", fmt.Errorf("missing %v", m)
		}
		return fmt.Sprintf("%d tools", len(names)), nil
	})
	b.check("tool-simple-text", "", func(ctx context.Context) (string, error) {
		res, err := b.call(ctx, "test_simple_text", nil)
		if err != nil {
			return "", err
		}
		if res.IsError || texts(res.Content) == "" {
			return "", fmt.Errorf("kinds %v", kinds(res.Content))
		}
		return texts(res.Content), nil
	})
	for _, c := range [][3]string{
		{"tool-image", "test_image_content", "image"}, {"tool-audio", "test_audio_content", "audio"},
		{"tool-embedded-resource", "test_embedded_resource", "resource"},
	} {
		b.check(c[0], "", func(ctx context.Context) (string, error) {
			res, err := b.call(ctx, c[1], nil)
			if err != nil {
				return "", err
			}
			k := kinds(res.Content)
			if len(k) != 1 || k[0] != c[2] {
				return "", fmt.Errorf("kinds %v", k)
			}
			switch v := res.Content[0].(type) {
			case *mcp.ImageContent:
				return fmt.Sprintf("%s, %d bytes", v.MIMEType, len(v.Data)), nil
			case *mcp.AudioContent:
				return fmt.Sprintf("%s, %d bytes", v.MIMEType, len(v.Data)), nil
			case *mcp.EmbeddedResource:
				return v.Resource.URI, nil
			}
			return c[2], nil
		})
	}
	b.check("tool-multiple-content", "", func(ctx context.Context) (string, error) {
		res, err := b.call(ctx, "test_multiple_content_types", nil)
		if err != nil {
			return "", err
		}
		if m := contains(kinds(res.Content), "text", "image", "resource"); len(m) > 0 {
			return "", fmt.Errorf("kinds %v", kinds(res.Content))
		}
		return strings.Join(kinds(res.Content), ","), nil
	})
	b.check("tool-error", "", func(ctx context.Context) (string, error) {
		res, err := b.call(ctx, "test_error_handling", nil)
		if err != nil {
			return "", err
		}
		if !res.IsError {
			return "", errors.New("isError false")
		}
		return texts(res.Content), nil
	})
	b.check("logging-set-level", "handshake", func(ctx context.Context) (string, error) {
		return "debug", b.cs.SetLoggingLevel(ctx, &mcp.SetLoggingLevelParams{Level: "debug"})
	})
	b.check("tool-logging", "", func(ctx context.Context) (string, error) {
		before := counts.logs.Load()
		if _, err := b.call(ctx, "test_tool_with_logging", nil); err != nil {
			return "", err
		}
		settle()
		if n := counts.logs.Load() - before; n > 0 {
			return fmt.Sprintf("%d log notifications", n), nil
		}
		return "", errors.New("no notifications/message")
	})
	b.check("tool-progress", "", func(ctx context.Context) (string, error) {
		before := counts.progress.Load()
		params := &mcp.CallToolParams{Meta: b.meta(), Name: "test_tool_with_progress"}
		params.SetProgressToken("interop-1")
		if _, err := b.cs.CallTool(ctx, params); err != nil {
			return "", err
		}
		settle()
		if n := counts.progress.Load() - before; n > 0 {
			return fmt.Sprintf("%d progress notifications", n), nil
		}
		return "", errors.New("no notifications/progress")
	})
	b.check("tool-sampling", "handshake", func(ctx context.Context) (string, error) {
		res, err := b.call(ctx, "test_sampling", map[string]any{"prompt": "Say hello"})
		if err != nil {
			return "", err
		}
		if res.IsError || !strings.Contains(texts(res.Content), "interop sampling reply") {
			return "", fmt.Errorf("isError %v: %s", res.IsError, texts(res.Content))
		}
		return texts(res.Content), nil
	})
	b.check("tool-elicitation", "handshake", func(ctx context.Context) (string, error) {
		res, err := b.call(ctx, "test_elicitation", map[string]any{"message": "Who are you?"})
		if err != nil {
			return "", err
		}
		if res.IsError || !strings.Contains(texts(res.Content), "accept") {
			return "", fmt.Errorf("isError %v: %s", res.IsError, texts(res.Content))
		}
		return texts(res.Content), nil
	})
	for _, c := range [][3]string{
		{"mrtr-elicitation", "test_input_required_result_elicitation", "elicitation"},
		{"mrtr-sampling", "test_input_required_result_sampling", "sampling"},
		{"mrtr-list-roots", "test_input_required_result_list_roots", "roots"},
		{"mrtr-multiple-inputs", "test_input_required_result_multiple_inputs", "elicitation"},
		{"mrtr-multi-round", "test_input_required_result_multi_round", "elicitation"},
	} {
		b.check(c[0], "stateless", func(ctx context.Context) (string, error) {
			counter := map[string]*atomic.Int64{"elicitation": &counts.elicitation, "sampling": &counts.sampling}[c[2]]
			var before int64
			if counter != nil {
				before = counter.Load()
			}
			res, err := b.call(ctx, c[1], nil)
			if err != nil {
				return "", err
			}
			if res.IsError {
				return "", fmt.Errorf("isError: %s", texts(res.Content))
			}
			text := texts(res.Content)
			if counter == nil { // roots: the Go client answers from AddRoots
				if !strings.Contains(text, "file:///tmp/interop") {
					return "", fmt.Errorf("roots not in %q", text)
				}
				return text, nil
			}
			n := counter.Load() - before
			if n == 0 {
				return "", errors.New("handler not called")
			}
			if len(text) > 80 {
				text = text[:80]
			}
			return fmt.Sprintf("%d handler calls: %s", n, text), nil
		})
	}
	b.check("unknown-tool", "", func(ctx context.Context) (string, error) {
		res, err := b.call(ctx, "interop_no_such_tool", nil)
		var rpcErr *jsonrpc.Error
		if errors.As(err, &rpcErr) {
			// Only the spec's unknown-tool code; -32603 is a server failure.
			if rpcErr.Code != -32602 {
				return "", fmt.Errorf("unexpected JSON-RPC error: %v", err)
			}
			return fmt.Sprintf("JSON-RPC error %d", rpcErr.Code), nil
		}
		if err != nil {
			return "", err
		}
		if !res.IsError {
			return "", errors.New("accepted")
		}
		return "isError result", nil
	})
	b.check("resources-list", "", func(ctx context.Context) (string, error) {
		res, err := b.cs.ListResources(ctx, nil)
		if err != nil {
			return "", err
		}
		var uris []string
		for _, r := range res.Resources {
			uris = append(uris, r.URI)
		}
		if m := contains(uris, "test://static-text", "test://static-binary"); len(m) > 0 {
			return "", fmt.Errorf("missing %v; have %v", m, uris)
		}
		return strings.Join(uris, ","), nil
	})
	b.check("resource-static-text", "", func(ctx context.Context) (string, error) {
		res, err := b.cs.ReadResource(ctx, &mcp.ReadResourceParams{URI: "test://static-text"})
		if err != nil {
			return "", err
		}
		if len(res.Contents) == 0 || res.Contents[0].Text == "" {
			return "", errors.New("no text")
		}
		return res.Contents[0].Text, nil
	})
	b.check("resource-static-binary", "", func(ctx context.Context) (string, error) {
		res, err := b.cs.ReadResource(ctx, &mcp.ReadResourceParams{URI: "test://static-binary"})
		if err != nil {
			return "", err
		}
		if len(res.Contents) == 0 || len(res.Contents[0].Blob) == 0 {
			return "", errors.New("no blob")
		}
		return fmt.Sprintf("%s, %d bytes", res.Contents[0].MIMEType, len(res.Contents[0].Blob)), nil
	})
	b.check("resource-templates-list", "", func(ctx context.Context) (string, error) {
		res, err := b.cs.ListResourceTemplates(ctx, nil)
		if err != nil {
			return "", err
		}
		var templates []string
		for _, t := range res.ResourceTemplates {
			templates = append(templates, t.URITemplate)
		}
		if m := contains(templates, "test://template/{id}/data"); len(m) > 0 {
			return "", fmt.Errorf("have %v", templates)
		}
		return strings.Join(templates, ","), nil
	})
	b.check("resource-template-read", "", func(ctx context.Context) (string, error) {
		res, err := b.cs.ReadResource(ctx, &mcp.ReadResourceParams{URI: "test://template/42/data"})
		if err != nil {
			return "", err
		}
		if len(res.Contents) == 0 || !strings.Contains(res.Contents[0].Text, "42") {
			return "", fmt.Errorf("contents %v", res.Contents)
		}
		return res.Contents[0].Text, nil
	})
	b.check("unknown-resource", "", func(ctx context.Context) (string, error) {
		_, err := b.cs.ReadResource(ctx, &mcp.ReadResourceParams{URI: "test://interop-missing"})
		var rpcErr *jsonrpc.Error
		if errors.As(err, &rpcErr) {
			// Resource not found: -32602 at 2026-07-28, -32002 at 2025-11-25.
			if rpcErr.Code != -32602 && rpcErr.Code != -32002 {
				return "", fmt.Errorf("unexpected JSON-RPC error: %v", err)
			}
			return fmt.Sprintf("JSON-RPC error %d", rpcErr.Code), nil
		}
		if err != nil {
			return "", fmt.Errorf("not a JSON-RPC error: %v", err)
		}
		return "", errors.New("accepted")
	})
	b.check("prompts-list", "", func(ctx context.Context) (string, error) {
		res, err := b.cs.ListPrompts(ctx, nil)
		if err != nil {
			return "", err
		}
		var names []string
		for _, p := range res.Prompts {
			names = append(names, p.Name)
		}
		if m := contains(names, "test_simple_prompt", "test_prompt_with_arguments",
			"test_prompt_with_embedded_resource", "test_prompt_with_image"); len(m) > 0 {
			return "", fmt.Errorf("missing %v", m)
		}
		return fmt.Sprintf("%d prompts", len(names)), nil
	})
	prompt := func(ctx context.Context, name string, args map[string]string) ([]*mcp.PromptMessage, error) {
		res, err := b.cs.GetPrompt(ctx, &mcp.GetPromptParams{Name: name, Arguments: args})
		if err != nil {
			return nil, err
		}
		return res.Messages, nil
	}
	b.check("prompt-simple", "", func(ctx context.Context) (string, error) {
		msgs, err := prompt(ctx, "test_simple_prompt", nil)
		if err != nil {
			return "", err
		}
		if len(msgs) == 0 {
			return "", errors.New("no messages")
		}
		return fmt.Sprintf("%d messages", len(msgs)), nil
	})
	b.check("prompt-arguments", "", func(ctx context.Context) (string, error) {
		msgs, err := prompt(ctx, "test_prompt_with_arguments", map[string]string{"arg1": "alpha", "arg2": "beta"})
		if err != nil {
			return "", err
		}
		var parts []string
		for _, m := range msgs {
			if t, ok := m.Content.(*mcp.TextContent); ok {
				parts = append(parts, t.Text)
			}
		}
		text := strings.Join(parts, " ")
		if !strings.Contains(text, "alpha") || !strings.Contains(text, "beta") {
			return "", fmt.Errorf("%q", text)
		}
		return text, nil
	})
	b.check("prompt-embedded-resource", "", func(ctx context.Context) (string, error) {
		msgs, err := prompt(ctx, "test_prompt_with_embedded_resource", map[string]string{"resourceUri": "test://static-text"})
		if err != nil {
			return "", err
		}
		for _, m := range msgs {
			if r, ok := m.Content.(*mcp.EmbeddedResource); ok {
				return r.Resource.URI, nil
			}
		}
		return "", errors.New("no embedded resource")
	})
	b.check("prompt-image", "", func(ctx context.Context) (string, error) {
		msgs, err := prompt(ctx, "test_prompt_with_image", nil)
		if err != nil {
			return "", err
		}
		for _, m := range msgs {
			if _, ok := m.Content.(*mcp.ImageContent); ok {
				return "image", nil
			}
		}
		return "", errors.New("no image")
	})
}

func waitFor(d time.Duration, cond func() bool) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
	return cond()
}

func (b *battery) runAdvanced() {
	// Header parameters (SEP-2243) come from the tool list.
	b.check("tools-list", "", func(ctx context.Context) (string, error) {
		res, err := b.cs.ListTools(ctx, nil)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("%d tools", len(res.Tools)), nil
	})
	b.check("concurrent-calls", "", func(ctx context.Context) (string, error) {
		var names []string
		for i := 0; i < 8; i++ {
			names = append(names, fmt.Sprintf("interop-c%d", i))
		}
		before := tokenCounts()
		var wg sync.WaitGroup
		errs := make(chan error, 16)
		for _, token := range names {
			wg.Add(1)
			go func() {
				defer wg.Done()
				params := &mcp.CallToolParams{Meta: b.meta(), Name: "test_tool_with_progress"}
				params.SetProgressToken(token)
				res, err := b.cs.CallTool(ctx, params)
				if err == nil && res.IsError {
					err = fmt.Errorf("%s: isError", token)
				}
				errs <- err
			}()
		}
		for i := 0; i < 4; i++ {
			wg.Add(2)
			go func() {
				defer wg.Done()
				res, err := b.call(ctx, "test_simple_text", nil)
				if err == nil && texts(res.Content) == "" {
					err = errors.New("simple text: empty")
				}
				errs <- err
			}()
			go func() {
				defer wg.Done()
				res, err := b.call(ctx, "test_image_content", nil)
				if err == nil && (len(res.Content) != 1 || kinds(res.Content)[0] != "image") {
					err = fmt.Errorf("image: %v", kinds(res.Content))
				}
				errs <- err
			}()
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			if err != nil {
				return "", err
			}
		}
		settle()
		after := tokenCounts()
		var silent []string
		for _, t := range names {
			if after[t] == before[t] {
				silent = append(silent, t)
			}
		}
		if len(silent) > 0 {
			return "", fmt.Errorf("no progress for %v", silent)
		}
		var stray []string
		for t := range after {
			if strings.HasPrefix(t, "interop-c") && !slices.Contains(names, t) {
				stray = append(stray, t)
			}
		}
		if len(stray) > 0 {
			return "", fmt.Errorf("progress for unknown tokens %v", stray)
		}
		return fmt.Sprintf("16 calls, progress kept apart for %d tokens", len(names)), nil
	})
	b.check("concurrent-input", "", func(ctx context.Context) (string, error) {
		type call struct {
			name string
			args map[string]any
		}
		var calls []call
		for i := 0; i < 4; i++ {
			if b.era == "handshake" {
				calls = append(calls, call{"test_sampling", map[string]any{"prompt": "Say hello"}},
					call{"test_elicitation", map[string]any{"message": "Who are you?"}})
			} else {
				calls = append(calls, call{"test_input_required_result_sampling", nil},
					call{"test_input_required_result_elicitation", nil})
			}
		}
		before := counts.sampling.Load() + counts.elicitation.Load()
		var wg sync.WaitGroup
		errs := make(chan error, len(calls))
		for _, c := range calls {
			wg.Add(1)
			go func() {
				defer wg.Done()
				res, err := b.call(ctx, c.name, c.args)
				if err == nil && res.IsError {
					err = fmt.Errorf("%s: %s", c.name, texts(res.Content))
				}
				errs <- err
			}()
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			if err != nil {
				return "", err
			}
		}
		handled := counts.sampling.Load() + counts.elicitation.Load() - before
		if handled < int64(len(calls)) {
			return "", fmt.Errorf("%d handler calls for %d tools", handled, len(calls))
		}
		return fmt.Sprintf("%d calls, %d handler calls", len(calls), handled), nil
	})
	b.check("cancel-then-continue", "", func(ctx context.Context) (string, error) {
		callCtx, cancel := context.WithCancel(ctx)
		go func() { time.Sleep(20 * time.Millisecond); cancel() }()
		params := &mcp.CallToolParams{Meta: b.meta(), Name: "test_tool_with_progress"}
		params.SetProgressToken("interop-cancel")
		outcome := "completed before the cancel"
		if _, err := b.cs.CallTool(callCtx, params); err != nil {
			outcome = "cancelled"
		}
		cancel()
		res, err := b.call(ctx, "test_simple_text", nil)
		if err != nil || texts(res.Content) == "" {
			return "", fmt.Errorf("the next call failed: %v", err)
		}
		return outcome + "; next call answered", nil
	})
	caps := b.cs.InitializeResult().Capabilities
	for _, c := range []struct {
		id, tool string
		counter  *atomic.Int64
		declared bool
		what     string
	}{
		{"tools-list-changed", "test_trigger_tool_change", &counts.toolsChanged,
			caps != nil && caps.Tools != nil && caps.Tools.ListChanged, "tools"},
		{"prompts-list-changed", "test_trigger_prompt_change", &counts.promptsChanged,
			caps != nil && caps.Prompts != nil && caps.Prompts.ListChanged, "prompts"},
	} {
		b.check(c.id, "", func(ctx context.Context) (string, error) {
			if !c.declared {
				return "", skip{"the server does not declare " + c.what + ".listChanged"}
			}
			before := c.counter.Load()
			if _, err := b.call(ctx, c.tool, nil); err != nil {
				return "", err
			}
			if !waitFor(3*time.Second, func() bool { return c.counter.Load() > before }) {
				return "", errors.New("no list_changed notification within 3 s")
			}
			return "notified", nil
		})
	}
	b.check("resource-subscribe", "", func(ctx context.Context) (string, error) {
		if caps == nil || caps.Resources == nil || !caps.Resources.Subscribe {
			return "", skip{"the server does not declare resources.subscribe"}
		}
		if err := b.cs.Subscribe(ctx, &mcp.SubscribeParams{URI: "test://watched-resource"}); err != nil {
			return "", err
		}
		return "subscribed", nil
	})
	b.check("resource-updated", "", func(ctx context.Context) (string, error) {
		if !*watchedFlag {
			return "", skip{"the server never updates test://watched-resource"}
		}
		if !waitFor(8*time.Second, func() bool { return counts.resourceUpdated.Load() > 0 }) {
			return "", errors.New("no notifications/resources/updated within 8 s")
		}
		return fmt.Sprintf("%d updates", counts.resourceUpdated.Load()), nil
	})
	b.check("reconnection", "", func(ctx context.Context) (string, error) {
		if !b.isHTTP {
			return "", skip{"HTTP only"}
		}
		res, err := b.call(ctx, "test_reconnection", nil)
		if err != nil {
			return "", err
		}
		if !strings.Contains(texts(res.Content), "Reconnection test completed") {
			return "", fmt.Errorf("%q", texts(res.Content))
		}
		return texts(res.Content), nil
	})
	for _, c := range [][2]string{{"mcp-param-header", "eu-west-1"}, {"mcp-param-header-unicode", "Zürich 東京"}} {
		b.check(c[0], "stateless", func(ctx context.Context) (string, error) {
			if !b.isHTTP {
				return "", skip{"HTTP only"}
			}
			// Header bindings come from the tool list; list_changed above invalidated it.
			if _, err := b.cs.ListTools(ctx, nil); err != nil {
				return "", err
			}
			res, err := b.call(ctx, "test_x_mcp_header", map[string]any{"region": c[1]})
			if err != nil {
				return "", err
			}
			if res.IsError || !strings.Contains(texts(res.Content), c[1]) {
				return "", fmt.Errorf("%q", texts(res.Content))
			}
			return texts(res.Content), nil
		})
	}
	b.check("streaming-elicitation", "", func(ctx context.Context) (string, error) {
		res, err := b.call(ctx, "test_streaming_elicitation", nil)
		if err != nil {
			return "", err
		}
		if res.IsError {
			return "", fmt.Errorf("%q", texts(res.Content))
		}
		return texts(res.Content), nil
	})
}

// pause tells the runner the session is ready and waits until it writes "go".
func pause(path string) error {
	if err := os.WriteFile(path, []byte("ready\n"), 0o644); err != nil {
		return err
	}
	for i := 0; i < 1200; i++ {
		if data, err := os.ReadFile(path); err == nil && strings.Contains(string(data), "go") {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return errors.New("the runner did not resume")
}

func (b *battery) runTool(args map[string]any) {
	b.check("tools-list", "", func(ctx context.Context) (string, error) {
		res, err := b.cs.ListTools(ctx, nil)
		if err != nil {
			return "", err
		}
		var names []string
		for _, t := range res.Tools {
			names = append(names, t.Name)
		}
		if m := contains(names, *toolFlag); len(m) > 0 {
			return "", fmt.Errorf("have %v", names)
		}
		return strings.Join(names, ","), nil
	})
	b.check("tool-call", "", func(ctx context.Context) (string, error) {
		res, err := b.call(ctx, *toolFlag, args)
		if err != nil {
			return "", err
		}
		if res.IsError || !strings.Contains(texts(res.Content), *expectFlag) {
			return "", fmt.Errorf("isError %v: %s", res.IsError, texts(res.Content))
		}
		return texts(res.Content), nil
	})
}

// answer fills every field of an elicitation form.
func answer(schema any) map[string]any {
	raw, _ := json.Marshal(schema)
	var s struct {
		Properties map[string]map[string]any `json:"properties"`
	}
	_ = json.Unmarshal(raw, &s)
	out := map[string]any{}
	for name, p := range s.Properties {
		if e, ok := p["enum"].([]any); ok && len(e) > 0 {
			out[name] = e[0]
			continue
		}
		if one, ok := p["oneOf"].([]any); ok && len(one) > 0 {
			if m, ok := one[0].(map[string]any); ok {
				out[name] = m["const"]
				continue
			}
		}
		if items, ok := p["items"].(map[string]any); ok {
			if e, ok := items["enum"].([]any); ok && len(e) > 0 {
				out[name] = []any{e[0]}
				continue
			}
			if any_, ok := items["anyOf"].([]any); ok && len(any_) > 0 {
				if m, ok := any_[0].(map[string]any); ok {
					out[name] = []any{m["const"]}
					continue
				}
			}
		}
		switch p["type"] {
		case "number", "integer":
			out[name] = 1
		case "boolean":
			out[name] = true
		default:
			if strings.Contains(strings.ToLower(name), "email") {
				out[name] = "interop@example.com"
			} else {
				out[name] = "interop"
			}
		}
	}
	return out
}

func newClient() *mcp.Client {
	client := mcp.NewClient(&mcp.Implementation{Name: "go-interop-client", Version: "1.0.0"}, &mcp.ClientOptions{
		CreateMessageHandler: func(context.Context, *mcp.CreateMessageRequest) (*mcp.CreateMessageResult, error) {
			counts.sampling.Add(1)
			return &mcp.CreateMessageResult{
				Model: "interop-model", Role: "assistant", StopReason: "endTurn",
				Content: &mcp.TextContent{Text: "interop sampling reply"},
			}, nil
		},
		ElicitationHandler: func(_ context.Context, req *mcp.ElicitRequest) (*mcp.ElicitResult, error) {
			counts.elicitation.Add(1)
			return &mcp.ElicitResult{Action: "accept", Content: answer(req.Params.RequestedSchema)}, nil
		},
		LoggingMessageHandler: func(context.Context, *mcp.LoggingMessageRequest) { counts.logs.Add(1) },
		ProgressNotificationHandler: func(_ context.Context, req *mcp.ProgressNotificationClientRequest) {
			counts.progress.Add(1)
			tokens.Lock()
			tokens.m[fmt.Sprint(req.Params.ProgressToken)]++
			tokens.Unlock()
		},
		ToolListChangedHandler:   func(context.Context, *mcp.ToolListChangedRequest) { counts.toolsChanged.Add(1) },
		PromptListChangedHandler: func(context.Context, *mcp.PromptListChangedRequest) { counts.promptsChanged.Add(1) },
		ResourceUpdatedHandler: func(context.Context, *mcp.ResourceUpdatedNotificationRequest) {
			counts.resourceUpdated.Add(1)
		},
	})
	client.AddRoots(&mcp.Root{URI: "file:///tmp/interop", Name: "interop"})
	return client
}

func newTransport() mcp.Transport {
	if *urlFlag != "" {
		return &mcp.StreamableClientTransport{Endpoint: *urlFlag}
	}
	if flag.NArg() > 0 {
		return &mcp.CommandTransport{Command: exec.Command(flag.Arg(0), flag.Args()[1:]...)}
	}
	return nil
}

func sessionOptions() *mcp.ClientSessionOptions {
	switch *eraFlag {
	case "handshake":
		return &mcp.ClientSessionOptions{ProtocolVersion: "2025-11-25"}
	case "stateless":
		return &mcp.ClientSessionOptions{ProtocolVersion: "2026-07-28"}
	}
	return nil
}

func main() {
	flag.Parse()
	client := newClient()
	transport := newTransport()
	if transport == nil {
		emit(map[string]any{"check": "arguments", "status": "fail", "detail": "pass -url or a command"})
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeoutFlag)
	cs, err := client.Connect(ctx, transport, sessionOptions())
	cancel()
	if err != nil {
		emit(map[string]any{"meta": map[string]any{"client": "go", "era": *eraFlag}})
		if *expectEra == "unsupported" {
			status := "fail"
			if rejectsProtocolVersion(err) {
				status = "pass"
			}
			emit(map[string]any{"check": "connect", "status": status, "detail": err.Error()})
			return
		}
		emit(map[string]any{"check": "connect", "status": "fail", "detail": err.Error()})
		os.Exit(1)
	}
	defer cs.Close()

	init := cs.InitializeResult()
	era := "handshake"
	if init.ProtocolVersion >= "2026-07-28" {
		era = "stateless"
	}
	server := "?"
	if init.ServerInfo != nil {
		server = init.ServerInfo.Name + " " + init.ServerInfo.Version
	}
	emit(map[string]any{"meta": map[string]any{
		"client": "go", "era": era, "protocolVersion": init.ProtocolVersion, "server": server}})
	if *expectEra == "unsupported" {
		// The client must not speak 2026-07-28 to a server without it: an error at
		// connect (above), a fallback to the handshake, or a rejected first request.
		if era == "handshake" {
			emit(map[string]any{"check": "connect", "status": "pass", "detail": "fell back to " + init.ProtocolVersion + " (handshake)"})
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), *timeoutFlag)
		defer cancel()
		_, err := cs.ListTools(ctx, nil)
		status, detail := "fail", init.ProtocolVersion+" accepted, expected unsupported"
		if err != nil {
			detail = "first request rejected: " + err.Error()
			if rejectsProtocolVersion(err) {
				status = "pass"
			}
		}
		emit(map[string]any{"check": "connect", "status": status, "detail": detail})
		return
	}
	expected := *expectEra
	if expected == "" && *eraFlag != "auto" {
		expected = *eraFlag
	}
	status := "pass"
	detail := fmt.Sprintf("%s (%s)", init.ProtocolVersion, era)
	if expected != "" {
		detail += ", expected " + expected
		if expected != era {
			status = "fail"
		}
	}
	emit(map[string]any{"check": "connect", "status": status, "detail": detail})

	b := &battery{cs: cs, era: era, isHTTP: *urlFlag != ""}
	switch *profileFlag {
	case "advanced":
		b.runAdvanced()
		return
	case "tasks":
		b.runTasks()
		return
	case "connect":
		b.check("tools-list", "", func(ctx context.Context) (string, error) {
			res, err := cs.ListTools(ctx, nil)
			if err != nil {
				return "", err
			}
			return fmt.Sprintf("%d tools", len(res.Tools)), nil
		})
		return
	case "session":
		b.check("session-before", "", func(ctx context.Context) (string, error) {
			res, err := b.call(ctx, "test_simple_text", nil)
			if err != nil {
				return "", err
			}
			return texts(res.Content), nil
		})
		if err := pause(*pauseFlag); err != nil {
			emit(map[string]any{"check": "session-expired", "status": "fail", "detail": err.Error()})
			return
		}
		b.check("session-expired", "", func(ctx context.Context) (string, error) {
			callCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			defer cancel()
			res, err := b.call(callCtx, "test_simple_text", nil)
			if errors.Is(err, context.DeadlineExceeded) {
				return "", errors.New("timed out after 10 s")
			}
			if err != nil {
				if !lostSession(err) {
					return "", fmt.Errorf("unexpected error: %w", err)
				}
				return "error: " + err.Error(), nil
			}
			return "recovered: " + texts(res.Content), nil
		})
		b.check("session-reconnect", "", func(ctx context.Context) (string, error) {
			fresh, err := newClient().Connect(ctx, newTransport(), sessionOptions())
			if err != nil {
				return "", err
			}
			defer fresh.Close()
			res, err := fresh.CallTool(ctx, &mcp.CallToolParams{Name: "test_simple_text"})
			if err != nil {
				return "", err
			}
			return texts(res.Content), nil
		})
		return
	}
	if *profileFlag == "tool" {
		var args map[string]any
		if err := json.Unmarshal([]byte(*argsFlag), &args); err != nil {
			emit(map[string]any{"check": "arguments", "status": "fail", "detail": err.Error()})
			os.Exit(2)
		}
		b.runTool(args)
	} else {
		b.runEverything()
	}
}
