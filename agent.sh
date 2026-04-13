#!/usr/bin/env bash
set -euo pipefail

# Colors
YOU="\033[94m"
ASSISTANT="\033[93m"
TOOL="\033[90m"
RESET="\033[0m"

# Config
OPENAI_API_URL="https://api.openai.com/v1/chat/completions"
MODEL="${OPENAI_MODEL:-gpt-4o}"

[[ -z "${OPENAI_API_KEY:-}" ]] && { echo "Error: OPENAI_API_KEY not set"; exit 1; }

# System prompt with tool definitions
read -r -d '' SYSTEM_PROMPT << 'PROMPT' || true
You are an interactive CLI-based coding agent. You help users with software engineering tasks including writing code, debugging, refactoring, and explaining code.

# Tool Use

You have access to a set of tools to help you complete tasks. To use a tool, output exactly one line in this format:

tool: TOOL_NAME({"param": "value", ...})

Use compact single-line JSON with double quotes. You will receive the result as: tool_result({...})

After receiving a tool result, continue working on the task. You may chain multiple tool calls across responses until the task is complete.

# Available Tools

## read_file
Read the contents of a file from the local filesystem.

Parameters:
- path (string, required): The path to the file to read. Can be relative or absolute.

Returns: JSON object with path and content fields.

Usage notes:
- Use this to examine existing code before making changes
- Always read a file before attempting to edit it
- If unsure which file to read, use list_files first to explore

Example:
tool: read_file({"path": "src/main.py"})

## list_files
List files and directories at a given path.

Parameters:
- path (string, required): The directory path to list. Use "." for current directory.

Returns: JSON object with path and files array (each with name and type).

Usage notes:
- Use this to explore project structure
- Helps you find relevant files before reading or editing
- Returns both files and subdirectories

Example:
tool: list_files({"path": "."})

## edit_file
Create a new file or edit an existing file using string replacement.

Parameters:
- path (string, required): The path to the file to create or edit.
- old_str (string, required): The text to search for and replace. Use empty string "" to create a new file.
- new_str (string, required): The text to replace old_str with. When creating a file, this is the full content.

Returns: JSON object with path and action (created/edited/old_str not found).

Usage notes:
- To CREATE a new file: set old_str to "" and new_str to the full file content
- To EDIT a file: set old_str to the exact text to find (including whitespace/indentation), and new_str to the replacement
- old_str must match EXACTLY - include enough context to uniquely identify the location
- Only the FIRST occurrence of old_str is replaced
- ALWAYS read_file before editing to see current content and ensure correct old_str
- For multiple edits to the same file, make them one at a time

Example (create):
tool: edit_file({"path": "hello.py", "old_str": "", "new_str": "def hello():\n    print(\"Hello World\")\n"})

Example (edit):
tool: edit_file({"path": "hello.py", "old_str": "print(\"Hello World\")", "new_str": "print(\"Hello, World!\")"})

# Guidelines

1. EXPLORE FIRST: Before editing, understand the codebase. Use list_files and read_file to gather context.

2. VERIFY BEFORE EDITING: Always read_file before edit_file to ensure you have the correct current content.

3. MAKE MINIMAL CHANGES: When editing, change only what is necessary. Preserve existing code style and formatting.

4. EXPLAIN YOUR WORK: After completing a task, briefly explain what you did and why.

5. HANDLE ERRORS GRACEFULLY: If a tool returns an error, explain the issue and try an alternative approach.

6. BE PRECISE: When using edit_file, include enough surrounding context in old_str to uniquely identify the edit location.

7. CHAIN OPERATIONS: Complex tasks may require multiple tool calls. Work step by step.

# Response Format

IMPORTANT: When a task requires using a tool, output ONLY the tool invocation line - no preamble, no explanation, just the tool call. Save explanations for AFTER you receive the tool result and complete the task.

Example of CORRECT behavior:
User: Create hello.py with a hello function
Assistant: tool: edit_file({"path": "hello.py", "old_str": "", "new_str": "def hello():\n    print(\"Hello\")\n"})

Example of INCORRECT behavior:
User: Create hello.py with a hello function
Assistant: I'll create that file for you now.
tool: edit_file(...)

Act immediately. Explain afterwards.
PROMPT

# Conversation state (JSON array)
CONVERSATION="[]"

# Add message to conversation
add_message() {
    local role="$1"
    local content="$2"
    CONVERSATION=$(echo "$CONVERSATION" | jq \
        --arg role "$role" \
        --arg content "$content" \
        '. + [{role: $role, content: $content}]')
}

# Call OpenAI API
call_llm() {
    local messages
    messages=$(echo "$CONVERSATION" | jq --arg system "$SYSTEM_PROMPT" \
        '[{role: "system", content: $system}] + .')
    
    local payload
    payload=$(jq -n \
        --arg model "$MODEL" \
        --argjson messages "$messages" \
        '{model: $model, messages: $messages, temperature: 0}')
    
    local response
    response=$(curl -s -X POST "$OPENAI_API_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -d "$payload")
    
    # Check for errors
    local error
    error=$(echo "$response" | jq -r '.error.message // empty')
    if [[ -n "$error" ]]; then
        echo "API Error: $error" >&2
        return 1
    fi
    
    echo "$response" | jq -r '.choices[0].message.content // empty'
}

# ==================== TOOLS ====================

tool_read_file() {
    local path="$1"
    local full_path
    full_path=$(realpath -m "$path" 2>/dev/null || echo "$path")
    
    if [[ ! -f "$full_path" ]]; then
        echo "{\"error\": \"File not found: $full_path\"}"
        return
    fi
    
    local content
    content=$(cat "$full_path")
    jq -n --arg path "$full_path" --arg content "$content" \
        '{path: $path, content: $content}'
}

tool_list_files() {
    local path="${1:-.}"
    local full_path
    full_path=$(realpath -m "$path" 2>/dev/null || echo "$path")
    
    if [[ ! -d "$full_path" ]]; then
        echo "{\"error\": \"Directory not found: $full_path\"}"
        return
    fi
    
    local files="[]"
    while IFS= read -r item; do
        local name type
        name=$(basename "$item")
        if [[ -d "$item" ]]; then
            type="dir"
        else
            type="file"
        fi
        files=$(echo "$files" | jq --arg name "$name" --arg type "$type" \
            '. + [{name: $name, type: $type}]')
    done < <(find "$full_path" -maxdepth 1 -mindepth 1 2>/dev/null | sort)
    
    jq -n --arg path "$full_path" --argjson files "$files" \
        '{path: $path, files: $files}'
}

tool_edit_file() {
    local path="$1"
    local old_str="$2"
    local new_str="$3"
    local full_path
    full_path=$(realpath -m "$path" 2>/dev/null || echo "$path")
    
    # Create parent directories if needed
    mkdir -p "$(dirname "$full_path")"
    
    if [[ -z "$old_str" ]]; then
        # Create or overwrite file
        printf '%s' "$new_str" > "$full_path"
        jq -n --arg path "$full_path" '{path: $path, action: "created"}'
    else
        # Replace in existing file
        if [[ ! -f "$full_path" ]]; then
            echo "{\"error\": \"File not found: $full_path\"}"
            return
        fi
        
        local content
        content=$(cat "$full_path")
        
        if [[ "$content" != *"$old_str"* ]]; then
            jq -n --arg path "$full_path" '{path: $path, action: "old_str not found"}'
            return
        fi
        
        # Replace first occurrence
        local new_content="${content/"$old_str"/$new_str}"
        printf '%s' "$new_content" > "$full_path"
        jq -n --arg path "$full_path" '{path: $path, action: "edited"}'
    fi
}

# ==================== TOOL PARSER ====================

# Extract tool call from response
# Returns: tool_name|json_args or empty
extract_tool_call() {
    local text="$1"
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^tool:[[:space:]]*([a-z_]+)\((.+)\)[[:space:]]*$ ]]; then
            local name="${BASH_REMATCH[1]}"
            local args="${BASH_REMATCH[2]}"
            echo "${name}|${args}"
            return 0
        fi
    done <<< "$text"
    
    return 1
}

# Execute a tool call
execute_tool() {
    local name="$1"
    local args_json="$2"
    
    case "$name" in
        read_file)
            local path
            path=$(echo "$args_json" | jq -r '.path // .filename // "."')
            tool_read_file "$path"
            ;;
        list_files)
            local path
            path=$(echo "$args_json" | jq -r '.path // "."')
            tool_list_files "$path"
            ;;
        edit_file)
            local path old_str new_str
            path=$(echo "$args_json" | jq -r '.path')
            old_str=$(echo "$args_json" | jq -r '.old_str')
            new_str=$(echo "$args_json" | jq -r '.new_str')
            tool_edit_file "$path" "$old_str" "$new_str"
            ;;
        *)
            echo "{\"error\": \"Unknown tool: $name\"}"
            ;;
    esac
}

# ==================== MAIN LOOP ====================

main() {
    echo "Bash Coding Agent (model: $MODEL)"
    echo "Type 'exit' or Ctrl+C to quit"
    echo ""
    
    while true; do
        # Get user input
        printf "${YOU}You:${RESET} "
        read -r user_input || break
        
        [[ "$user_input" == "exit" ]] && break
        [[ -z "$user_input" ]] && continue
        
        add_message "user" "$user_input"
        
        # Inner loop: keep calling LLM until no tool calls
        while true; do
            local response
            response=$(call_llm)
            
            if [[ -z "$response" ]]; then
                echo "Error: Empty response from LLM"
                break
            fi
            
            # Check for tool call
            local tool_info
            if tool_info=$(extract_tool_call "$response"); then
                local tool_name="${tool_info%%|*}"
                local tool_args="${tool_info#*|}"
                
                printf "${TOOL}[tool: %s(%s)]${RESET}\n" "$tool_name" "$tool_args"
                
                # Execute tool
                local result
                result=$(execute_tool "$tool_name" "$tool_args")
                
                printf "${TOOL}[result: %s]${RESET}\n" "$(echo "$result" | jq -c .)"
                
                # Add assistant response and tool result to conversation
                add_message "assistant" "$response"
                add_message "user" "tool_result($result)"
            else
                # No tool call, print response and break inner loop
                printf "${ASSISTANT}Assistant:${RESET} %s\n" "$response"
                add_message "assistant" "$response"
                break
            fi
        done
        
        echo ""
    done
}

main
