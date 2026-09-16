#!/bin/bash
# Spoken status channel for Claude Code hooks — receives hook JSON on stdin.
# Wired to Stop, SubagentStart, SubagentStop, Notification in ~/.claude/settings.json.
#
# Fixed minimal lexicon (Nick multitasks by ear; four phrases, nothing else):
#   "done"                      — turn complete
#   "handing off to X"          — agent dispatched
#   "X returned. <diagnosis>"   — agent back, Haiku-compressed finding (<=10 words)
#   "Claude needs your attention" — chime + fixed phrase, any notification
#
# The CLAUDE_SPEAK_INNER guard stops the inner `claude -p` summarizer from
# re-triggering this script (infinite recursion).

[ -n "$CLAUDE_SPEAK_INNER" ] && exit 0
# Mute switch: `claude-audio off` creates this file, `claude-audio on` removes it.
[ -f "$HOME/.claude/hooks/speak.off" ] && exit 0

payload=$(cat)
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // ""')
CLAUDE_BIN="${CLAUDE_BIN:-/opt/homebrew/bin/claude}"

# Strip markdown and collapse whitespace so `say` reads clean prose.
clean() {
  sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' | tr '\n\r' '  ' | sed -E 's/[*`#_>|]//g; s/https?:\/\/[^ ]*//g; s/  +/ /g; s/^ +//'
}

case "$event" in
  Stop)
    msg=$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty')
    # No message = lifecycle stop (clear/resume/compact). Silence.
    [ -z "$msg" ] && exit 0
    say "[[volm 0.55]] done"
    ;;
  SubagentStart)
    t=$(printf '%s' "$payload" | jq -r '(.agent_type // "agent") | gsub("-"; " ")')
    say "[[volm 0.45]] handing off to $t"
    ;;
  SubagentStop)
    t=$(printf '%s' "$payload" | jq -r '(.agent_type // "agent") | gsub("-"; " ")')
    report=$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty')
    if [ -n "$report" ]; then
      s=$(printf '%s' "$report" | head -c 4000 | CLAUDE_SPEAK_INNER=1 "$CLAUDE_BIN" -p \
        --model haiku --settings '{"disableAllHooks":true}' \
        "An agent just returned this report. In at most 10 plain spoken words, state its key finding or result. No preamble, no markdown, no file paths." \
        2>/dev/null | clean)
      if [ -n "$s" ]; then
        say "[[volm 0.5]] $t returned. ${s:0:200}"
        exit 0
      fi
    fi
    say "[[volm 0.5]] $t returned"
    ;;
  Notification)
    afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1
    say "[[volm 0.7]] Claude needs your attention"
    ;;
esac
