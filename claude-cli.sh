# claude-cli.sh
# Account-aware launcher for Claude Code (Linux, bash 4+). Requires jq.
# https://github.com/keven-bardales/claude-account-switcher
#
# Bash port of claude-cli.ps1 - same logic, same ~/.claude-accounts.json.
# Source it from ~/.bashrc (install.sh does this). Every `claude` run:
#   - resolves the account from your folder/repo (byPath -> byOrg -> default),
#   - SHOWS you which account it will use,
#   - asks you to confirm before launching,
#   - passes all your flags through unchanged.
#
# Personal is the safe default. Another account is used ONLY where YOU mapped it
# in ~/.claude-accounts.json. Config CLI: `cca` (run `cca help`).

CC_FILE="$HOME/.claude-accounts.json"

# --- output helpers (banner/prompts go to stderr so `claude -p ... > out` stays clean)

_cc_c() { # _cc_c <color> <text...>
  local code
  case "$1" in
    red) code=31 ;; green) code=32 ;; yellow) code=33 ;; cyan) code=36 ;; gray) code=90 ;; *) code=0 ;;
  esac
  shift
  if [ -t 2 ]; then printf '\033[%sm%s\033[0m\n' "$code" "$*" >&2; else printf '%s\n' "$*" >&2; fi
}

# --- config -----------------------------------------------------------------

# Prints: ok | missing | invalid | nojq
_cc_config_state() {
  [ -f "$CC_FILE" ] || { echo missing; return; }
  command -v jq >/dev/null 2>&1 || { echo nojq; return; }
  jq -e 'type == "object"' "$CC_FILE" >/dev/null 2>&1 && echo ok || echo invalid
}

_cc_init_config() {
  jq -n --arg work "$HOME/.claude-work" \
    '{default: "personal", profiles: {personal: "", work: $work}, byPath: {}, byOrg: {}}' > "$CC_FILE" || return 1
  _cc_c green "Created $CC_FILE"
  _cc_c gray "Edit it (cca edit) to add profiles + folder/org rules."
}

_cc_has_profile() { # _cc_has_profile <name>
  jq -e --arg p "$1" '(.profiles // {}) | has($p)' "$CC_FILE" >/dev/null 2>&1
}

_cc_profile_names() {
  jq -r '(.profiles // {}) | keys_unsorted | join(", ")' "$CC_FILE" 2>/dev/null
}

_cc_config_dir() { # _cc_config_dir <profile>  -> dir ('' = default ~/.claude)
  local d
  d=$(jq -r --arg p "$1" '(.profiles // {})[$p] // "" | tostring' "$CC_FILE" 2>/dev/null)
  case "$d" in "~") d="$HOME" ;; "~/"*) d="$HOME/${d#\~/}" ;; esac
  printf '%s' "$d"
}

_cc_git_org() {
  local url clean
  url=$(git config --get remote.origin.url 2>/dev/null) || return 0
  [ -n "$url" ] || return 0
  clean="${url%"${url##*[![:space:]]}"}"
  clean="${clean%.git}"
  clean="${clean//:/\/}"
  # second-to-last non-empty path segment
  printf '%s' "$clean" | tr '/' '\n' | sed '/^$/d' | tail -n 2 | head -n 1
}

# Sets CC_PROFILE, CC_DIR, CC_REASON, CC_SOURCE (byPath|byOrg|default|missing|invalid|nojq)
_cc_resolve() {
  local state
  state=$(_cc_config_state)
  CC_PROFILE=personal; CC_DIR=''
  case "$state" in
    missing) CC_REASON='accounts config not found'; CC_SOURCE=missing; return ;;
    invalid) CC_REASON='accounts config is invalid JSON'; CC_SOURCE=invalid; return ;;
    nojq)    CC_REASON="'jq' is not installed (needed to read the accounts config)"; CC_SOURCE=nojq; return ;;
  esac

  local default cwd
  default=$(jq -r '.default // "personal" | tostring' "$CC_FILE")
  [ -n "$default" ] || default=personal
  cwd=$(pwd)

  # 1) byPath - longest matching prefix wins (a folder OR a specific repo)
  local base prof best_base='' best_prof='' best_len=-1
  while IFS=$'\t' read -r base prof; do
    while [ "${base%/}" != "$base" ]; do base="${base%/}"; done
    case "$base" in "~") base="$HOME" ;; "~/"*) base="$HOME/${base#\~/}" ;; esac
    [ -n "$base" ] || continue
    if [ "$cwd" = "$base" ] || [ "${cwd#"$base"/}" != "$cwd" ]; then
      if [ "${#base}" -gt "$best_len" ]; then best_len=${#base}; best_base=$base; best_prof=$prof; fi
    fi
  done < <(jq -r '(.byPath // {}) | to_entries[] | "\(.key)\t\(.value)"' "$CC_FILE")
  if [ -n "$best_prof" ]; then
    CC_PROFILE=$best_prof; CC_DIR=$(_cc_config_dir "$best_prof")
    CC_REASON="path match: $best_base"; CC_SOURCE=byPath; return
  fi

  # 2) byOrg - from the repo's git remote owner
  local org
  org=$(_cc_git_org)
  if [ -n "$org" ]; then
    # case-insensitive, like GitHub (and the PowerShell version)
    prof=$(jq -r --arg o "$org" \
      '[(.byOrg // {}) | to_entries[] | select((.key | ascii_downcase) == ($o | ascii_downcase)) | .value][0] // empty | tostring' \
      "$CC_FILE")
    if [ -n "$prof" ]; then
      CC_PROFILE=$prof; CC_DIR=$(_cc_config_dir "$prof")
      CC_REASON="git org: $org"; CC_SOURCE=byOrg; return
    fi
  fi

  # 3) default
  CC_PROFILE=$default; CC_DIR=$(_cc_config_dir "$default")
  CC_REASON='default (no match)'; CC_SOURCE=default
}

_cc_logged_in() { # _cc_logged_in <dir>
  if [ -z "$1" ]; then [ -f "$HOME/.claude/.credentials.json" ]; else [ -f "$1/.credentials.json" ]; fi
}

# Runs the real claude binary with CLAUDE_CONFIG_DIR set to <dir> (or unset for '').
# Runs in a subshell, so the caller's environment is never touched.
_cc_exec() { # _cc_exec <dir> [args...]
  local dir=$1; shift
  (
    if [ -z "$dir" ]; then
      unset CLAUDE_CONFIG_DIR
    else
      mkdir -p "$dir" || exit 1
      export CLAUDE_CONFIG_DIR="$dir"
    fi
    command claude "$@"
  )
}

# --- the wrapper ------------------------------------------------------------

claude() {
  if ! type -P claude >/dev/null 2>&1; then
    _cc_c red "X  Real 'claude' executable not found on PATH."; return 1
  fi

  local CC_PROFILE CC_DIR CC_REASON CC_SOURCE
  _cc_resolve
  local profile=$CC_PROFILE dir=$CC_DIR

  local auto_yes=0
  if [ "${CLAUDE_ACCOUNT_YES:-}" = 1 ] || [ ! -t 0 ]; then auto_yes=1; fi

  # Edge case: config file missing/broken (or no jq) -> ask before proceeding (safe default = personal)
  case "$CC_SOURCE" in
    missing|invalid|nojq)
      echo >&2
      _cc_c yellow "!  $CC_REASON. Safe fallback = PERSONAL."
      if [ "$auto_yes" != 1 ]; then
        local a
        read -r -p "   Proceed with PERSONAL? [Y]es / [n]o / [r]ecreate config " a
        case "$a" in
          [rR]*)
            if command -v jq >/dev/null 2>&1; then
              _cc_init_config && _cc_c gray "   Re-run 'claude' now."
            else
              _cc_c red "   Install jq first (e.g. sudo apt install jq)."
            fi
            return 0 ;;
          [nN]*) _cc_c gray "   Cancelled."; return 0 ;;
        esac
      fi
      profile=personal; dir='' ;;
  esac

  local tag="[$profile]"

  echo >&2
  _cc_c gray "  +-- Claude account --------------------------------"
  _cc_c cyan "  | account : $profile $tag"
  _cc_c gray "  | why     : $CC_REASON"
  if [ -z "$dir" ]; then _cc_c gray "  | config  : default (~/.claude)"; else _cc_c gray "  | config  : $dir"; fi
  if ! _cc_logged_in "$dir"; then _cc_c yellow "  | login   : NOT logged in yet -> Claude will prompt you to /login"; fi
  _cc_c gray "  +--------------------------------------------------"

  if [ "$auto_yes" != 1 ]; then
    local -a names=()
    [ "$(_cc_config_state)" = ok ] && mapfile -t names < <(jq -r '(.profiles // {}) | keys_unsorted[]' "$CC_FILE")
    local i opts=''
    for i in "${!names[@]}"; do opts+="  $((i + 1))) ${names[$i]}"; done
    _cc_c gray "  [Enter] = $profile   |${opts:-  (no profiles)}   |  n = cancel"
    local resp
    read -r -p "  Account? " resp
    if [[ "$resp" =~ ^[0-9]+$ ]] && [ "$resp" -ge 1 ] && [ "$resp" -le "${#names[@]}" ]; then
      resp=${names[$((resp - 1))]}
    fi
    case "$resp" in
      [nN]|[nN][oO]) _cc_c gray "  Cancelled."; return 0 ;;
      ''|[yY]|"$profile") ;;
      *)
        if [ "$(_cc_config_state)" = ok ] && _cc_has_profile "$resp"; then
          profile=$resp; dir=$(_cc_config_dir "$resp")
          _cc_c cyan "  -> override: $profile"
        else
          _cc_c red "  Unknown profile '$resp'. Cancelled."; return 1
        fi ;;
    esac
  fi

  _cc_exec "$dir" "$@"
}

# --- config CLI: cca --------------------------------------------------------

cca() {
  local cmd=${1:-help}
  [ $# -gt 0 ] && shift
  case "$cmd" in
    which)
      local CC_PROFILE CC_DIR CC_REASON CC_SOURCE
      _cc_resolve
      _cc_c cyan "$CC_PROFILE   ($CC_REASON)"
      ;;
    list)
      if [ -f "$CC_FILE" ]; then cat "$CC_FILE"
      else _cc_c yellow "No config at $CC_FILE  (run: cca init)"; fi
      ;;
    edit) "${EDITOR:-nano}" "$CC_FILE" ;;
    path) echo "$CC_FILE" ;;
    init)
      command -v jq >/dev/null 2>&1 || { _cc_c red "jq is required (e.g. sudo apt install jq)."; return 1; }
      _cc_init_config
      ;;
    set)
      local prof=${1:-} target=${2:-}
      if [ -z "$prof" ]; then echo "Usage: cca set <profile> [path]   (path defaults to current folder)"; return 1; fi
      if [ "$(_cc_config_state)" != ok ]; then _cc_c yellow "Config missing/invalid (or jq missing). Run: cca init"; return 1; fi
      if ! _cc_has_profile "$prof"; then
        _cc_c red "Unknown profile '$prof'. Known: $(_cc_profile_names)"; return 1
      fi
      [ -n "$target" ] || target=$(pwd)
      local tmp
      tmp=$(mktemp "${CC_FILE}.XXXXXX") || return 1
      if jq --arg k "$target" --arg v "$prof" '.byPath = ((.byPath // {}) + {($k): $v})' "$CC_FILE" > "$tmp"; then
        mv "$tmp" "$CC_FILE"
        _cc_c green "Mapped  $target  ->  $prof"
      else
        rm -f "$tmp"; return 1
      fi
      ;;
    login)
      local prof=${1:-}
      [ $# -gt 0 ] && shift
      if [ "$(_cc_config_state)" != ok ] || [ -z "$prof" ] || ! _cc_has_profile "$prof"; then
        local known='(none)'
        [ "$(_cc_config_state)" = ok ] && known=$(_cc_profile_names)
        _cc_c yellow "Usage: cca login <profile>   known: $known"; return 1
      fi
      if ! type -P claude >/dev/null 2>&1; then _cc_c red "X  Real 'claude' executable not found."; return 1; fi
      _cc_c cyan "Opening Claude for profile '$prof'. Inside, run  /login  if it doesn't prompt automatically."
      _cc_exec "$(_cc_config_dir "$prof")" "$@"
      ;;
    *)
      cat <<'EOF'
cca - Claude account config
  cca which              show which account THIS folder resolves to
  cca list               print ~/.claude-accounts.json
  cca edit               open the config in $EDITOR (default: nano)
  cca set <profile> [p]  map a folder (default: current) to a profile
  cca login <profile>    open Claude in a profile so you can /login
  cca init               (re)create a starter config
  cca path               print the config file path

Tip: at the 'claude' confirm prompt, type a profile name to override once.
     Set CLAUDE_ACCOUNT_YES=1 to skip the prompt (scripts/CI).
EOF
      ;;
  esac
}
