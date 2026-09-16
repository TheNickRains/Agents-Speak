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

# One perceived loudness everywhere (Nick: "consistency of volume level").
# Voices differ wildly in native gain — legacy US voices run hot, so they
# get a lower volm to land at the same level as Samantha at 0.55.
VOL=0.55
gain_for() {
  case "$1" in
    Fred|Ralph|Kathy|Junior|Albert) echo "0.35" ;;
    Daniel)                         echo "0.6"  ;;
    *)                              echo "$VOL" ;;
  esac
}

# Stable voice per persona so Nick can follow multi-agent work by ear.
# Chair/main channel stays Samantha (default); agents get distinct accents.
voice_for() {
  case "$1" in
    architect)            echo "Daniel" ;;   # GB — measured
    scientist)            echo "Rishi" ;;    # IN
    strategist)           echo "Moira" ;;    # IE
    senior-engineer)      echo "Ralph" ;;    # US gravel
    ux)                   echo "Karen" ;;    # AU
    fullstack)            echo "Fred" ;;     # US robotic — the builder
    designer)             echo "Tessa" ;;    # ZA
    scrum-master)         echo "Kathy" ;;    # US
    general)              echo "Aman" ;;     # IN
    recorder)             echo "Tara" ;;     # IN
    naieve-copywriter)    echo "Junior" ;;   # childlike — 5th-grade cap
    technical-copywriter) echo "Tara" ;;
    *)
      # Unknown agent types: stable hash into the distinct-voice pool.
      voices=(Daniel Karen Moira Rishi Tessa Tara Aman Kathy Ralph)
      n=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
      echo "${voices[$((n % ${#voices[@]}))]}"
      ;;
  esac
}

case "$event" in
  Stop)
    msg=$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty')
    # No message = lifecycle stop (clear/resume/compact). Silence.
    [ -z "$msg" ] && exit 0
    say "[[volm $VOL]] done"
    ;;
  SubagentStart)
    t=$(printf '%s' "$payload" | jq -r '(.agent_type // "agent") | gsub("-"; " ")')
    say "[[volm $VOL]] handing off to $t"
    ;;
  SubagentStop)
    raw_t=$(printf '%s' "$payload" | jq -r '.agent_type // "agent"')
    t=$(printf '%s' "$raw_t" | tr '-' ' ')
    v=$(voice_for "$raw_t")
    report=$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty')
    if [ -n "$report" ]; then
      s=$(printf '%s' "$report" | head -c 4000 | CLAUDE_SPEAK_INNER=1 "$CLAUDE_BIN" -p \
        --model haiku --settings '{"disableAllHooks":true}' \
        "An agent just returned this report. In at most 10 plain spoken words, state its key finding or result. No preamble, no markdown, no file paths." \
        2>/dev/null | clean)
      if [ -n "$s" ]; then
        g=$(gain_for "$v")
        say -v "$v" "[[volm $g]] $t returned. ${s:0:200}" || say "[[volm $VOL]] $t returned. ${s:0:200}"
        exit 0
      fi
    fi
    g=$(gain_for "$v")
    say -v "$v" "[[volm $g]] $t returned" || say "[[volm $VOL]] $t returned"
    ;;
  Notification)
    afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1
    say "[[volm $VOL]] Claude needs your attention"
    ;;
  PreToolUse)
    printf '%s' "$payload" >/tmp/claude-pretool-payload.json
    # Mid-turn status callouts — spoken versions of the transcript's inline
    # status lines. Throttled: at most one every 20s, or bursts machine-gun.
    now=$(date +%s)
    last=$(cat /tmp/claude-speak-throttle 2>/dev/null || echo 0)
    [ $((now - last)) -lt 20 ] && exit 0
    tool=$(printf '%s' "$payload" | jq -r '.tool_name // ""')
    line=""
    case "$tool" in
      Bash)       line=$(printf '%s' "$payload" | jq -r '.tool_input.description // empty' | clean) ;;
      Edit|Write) f=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty'); [ -n "$f" ] && line="editing ${f##*/}" ;;
      Skill)      line="running $(printf '%s' "$payload" | jq -r '.tool_input.skill // "a skill"')" ;;
      WebSearch)  line="searching the web" ;;
      WebFetch)   line="reading a page" ;;
      Workflow)   line="starting a workflow" ;;
      mcp__*)     srv=$(printf '%s' "$tool" | awk -F'__' '{print $2}' | tr '_' ' '); line="calling $srv" ;;
    esac
    [ -z "$line" ] && exit 0
    echo "$now" >/tmp/claude-speak-throttle
    say "[[volm $VOL]] ${line:0:80}"
    ;;
esac
