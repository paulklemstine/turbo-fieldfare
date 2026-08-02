#!/usr/bin/env python3
"""Minimal chat client for the TurboFieldfare local model server.

Two modes:
  chat.py --ask "PROMPT"   run a single prompt and print the reply
  chat.py --chat           interactive chat REPL
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

DEFAULT_BASE_URL = "http://127.0.0.1:8080/v1"
DEFAULT_MODEL = "gemma-4-26b-a4b-it"


def send(messages, args):
    body = json.dumps({
        "model": args.model,
        "messages": messages,
        "temperature": args.temperature,
        "max_completion_tokens": args.max_tokens,
        "stream": not args.no_stream,
        "stop": ["<end_of_turn>"],
    }).encode("utf-8")
    req = urllib.request.Request(
        args.base_url.rstrip("/") + "/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    try:
        resp = urllib.request.urlopen(req, timeout=None)
    except urllib.error.HTTPError as e:
        print("ERROR %s: %s" % (e.code, e.read().decode("utf-8", errors="replace")), file=sys.stderr)
        return None
    except urllib.error.URLError as e:
        print("ERROR: cannot reach the model server at %s (%s)" % (args.base_url, e.reason), file=sys.stderr)
        print("       Is TurboFieldfareServer running? Use start.sh to launch it.", file=sys.stderr)
        return None

    if args.no_stream:
        data = json.loads(resp.read().decode("utf-8"))
        msg = data["choices"][0]["message"]
        reply = msg.get("content") or msg.get("reasoning_content") or ""
        print(reply)
        return reply

    text = ""
    reasoning = ""
    for raw in resp:
        line = raw.decode("utf-8", errors="replace").strip()
        if not line.startswith("data:"):
            continue
        payload = line[len("data:"):].strip()
        if payload == "[DONE]":
            break
        try:
            chunk = json.loads(payload)
        except json.JSONDecodeError:
            continue
        choices = chunk.get("choices") or []
        if not choices:
            continue
        delta = choices[0].get("delta", {})
        content = delta.get("content")
        if content:
            text += content
            sys.stdout.write(content)
            sys.stdout.flush()
        rc = delta.get("reasoning_content")
        if rc:
            reasoning += rc
    sys.stdout.write("\n")
    sys.stdout.flush()
    # If the model used a "thinking" architecture and put everything in
    # reasoning_content, surface that instead of an empty reply.
    if not text and reasoning:
        sys.stdout.write(reasoning)
        sys.stdout.write("\n")
        sys.stdout.flush()
        return reasoning
    return text


def main():
    parser = argparse.ArgumentParser(description="Chat with the TurboFieldfare local model server.")
    parser.add_argument("--chat", action="store_true", help="interactive chat REPL")
    parser.add_argument("--ask", nargs="?", const="", default=None, help="single prompt (reads stdin if empty)")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help="OpenAI-compatible base URL")
    parser.add_argument("--model", default=DEFAULT_MODEL, help="model id")
    parser.add_argument("--temperature", type=float, default=0.2)
    parser.add_argument("--max-tokens", type=int, default=4096)
    parser.add_argument("--system", default=None, help="system prompt for the session")
    parser.add_argument("--no-stream", action="store_true", help="wait for the full reply instead of streaming")
    args = parser.parse_args()

    if not args.chat and args.ask is None:
        parser.print_help()
        sys.exit(1)

    messages = []
    if args.system:
        messages.append({"role": "system", "content": args.system})

    if args.ask is not None:
        prompt = args.ask
        if not prompt and not sys.stdin.isatty():
            prompt = sys.stdin.read().strip()
        if not prompt:
            parser.error("--ask requires a prompt argument or piped stdin")
        messages.append({"role": "user", "content": prompt})
        if send(messages, args) is None:
            sys.exit(1)
        return

    print("TurboFieldfare chat (%s). /quit to exit." % args.model)
    try:
        while True:
            try:
                user = input("you> ").strip()
            except EOFError:
                break
            if not user:
                continue
            if user in ("/quit", "/exit", "/q"):
                break
            if user == "/new":
                messages = [m for m in messages if m["role"] == "system"]
                print("(history cleared)")
                continue
            messages.append({"role": "user", "content": user})
            print("gemma> ", end="", flush=True)
            reply = send(messages, args)
            if reply is None:
                messages.pop()
                sys.exit(1)
            else:
                messages.append({"role": "assistant", "content": reply})
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
