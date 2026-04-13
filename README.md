# coding-agent.sh

A minimal AI coding agent in ~200 lines of bash. Inspired by [The Emperor Has No Clothes](https://www.mihaileric.com/The-Emperor-Has-No-Clothes/).

## What is this?

A fully functional coding assistant that can read, create, and edit files in your project. It's a conversation loop with an LLM that has access to tools - the same core architecture as Claude Code, Cursor, and other AI coding tools.

## Requirements

- bash
- curl
- jq
- OpenAI API key

## Usage

```bash
export OPENAI_API_KEY="sk-..."
./agent.sh
```

Use a different model:

```bash
OPENAI_MODEL=gpt-4o-mini ./agent.sh
```

## Example Session

```
$ ./agent.sh
Bash Coding Agent (model: gpt-4o)
Type 'exit' or Ctrl+C to quit

You: Create hello.py with a function that prints hello world
[tool: edit_file({"path": "hello.py", "old_str": "", "new_str": "def hello():\n    print(\"Hello World\")\n"})]
[result: {"path":"hello.py","action":"created"}]
Assistant: Created hello.py with a hello world function.

You: Add a goodbye function to it
[tool: read_file({"path": "hello.py"})]
[result: {"path":"hello.py","content":"def hello():\n    print(\"Hello World\")\n"}]
[tool: edit_file({"path": "hello.py", "old_str": "print(\"Hello World\")\n", "new_str": "print(\"Hello World\")\n\ndef goodbye():\n    print(\"Goodbye!\")\n"})]
[result: {"path":"hello.py","action":"edited"}]
Assistant: Added a goodbye function to hello.py.
```

## Tools

| Tool | Description |
|------|-------------|
| `read_file(path)` | Read contents of a file |
| `list_files(path)` | List directory contents |
| `edit_file(path, old_str, new_str)` | Create file (empty old_str) or find/replace edit |

## How It Works

1. **Chat loop** - prompts for user input, maintains conversation history
2. **LLM call** - sends conversation to OpenAI API
3. **Tool parsing** - detects `tool: name({...})` in response
4. **Tool execution** - runs tool locally, feeds result back as `tool_result(...)`
5. **Repeat** - continues until LLM responds without a tool call

The "magic" is in the LLM, not the harness. This is just a ~200 SLOC wrapper that gives the model hands.

## Extending

Add more tools by:

1. Creating a `tool_xxx()` function
2. Adding it to the `execute_tool()` case statement
3. Documenting it in `SYSTEM_PROMPT`

Ideas: `bash` (run commands), `grep` (search code), `glob` (find files), `web_fetch` (read URLs)

## License

MIT
