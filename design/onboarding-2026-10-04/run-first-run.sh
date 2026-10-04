#!/bin/bash
# First run, end to end, as a brand-new account — against a SCRATCH copy of the database.
# Production is never written: the server below refuses any database but the scratch one.
#
#   ./run-first-run.sh <simulator-udid> [extra launch args…]
#
# One-time: createdb previously_onboarding_scratch &&
#           pg_dump previously -Fc --no-owner --no-privileges | pg_restore --no-owner --no-privileges -d previously_onboarding_scratch
# Afterwards: dropdb previously_onboarding_scratch
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
U="${1:?simulator udid}"; shift
PORT=8799

if ! curl -s -m 2 "http://127.0.0.1:$PORT/health" >/dev/null; then
  ( cd "$ROOT/server" && APP_ENV=development PORT=$PORT DEV_AUTH_BYPASS=1 \
      DATABASE_URL=postgres://localhost:5432/previously_onboarding_scratch \
      NEWS_AGENT_DISABLED=1 NEWS_CODEX_FALLBACK_ENABLED=0 SEARCH_CORRECT_DISABLED=1 GROUPING_LLM_DISABLED=1 \
      OPENROUTER_API_KEY= CEREBRAS_API_KEY= ANTHROPIC_API_KEY= CLERK_SECRET_KEY= MODERATION_ALERT_WEBHOOK_URL= \
      nohup npx tsx "$HERE/scratch-entry.mts" > "$HERE/scratch-server.local.log" 2>&1 & )
  for _ in $(seq 1 30); do curl -s -m 1 "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 1; done
fi
curl -s -m 2 "http://127.0.0.1:$PORT/health" >/dev/null || { echo "scratch server did not start (see scratch-server.local.log)"; exit 1; }

cd "$ROOT/ios" && xcodegen generate >/dev/null 2>&1
xcodebuild -project Previously.xcodeproj -scheme Previously -configuration Debug \
  -destination "platform=iOS Simulator,id=$U" -derivedDataPath build/DerivedData-firstrun \
  "API_BASE_URL=http://localhost:$PORT" "CLERK_PUBLISHABLE_KEY=" build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u | tail -5
APP="build/DerivedData-firstrun/Build/Products/Debug-iphonesimulator/Previously.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :APIBaseURL' "$APP/Info.plist")" = "http://localhost:$PORT" ] || { echo "wrong API base in the build"; exit 1; }

# A clean install is a clean device; a new id is a new account.
xcrun simctl terminate "$U" com.cognipin.previously >/dev/null 2>&1
xcrun simctl uninstall "$U" com.cognipin.previously >/dev/null 2>&1
xcrun simctl install "$U" "$APP"
xcrun simctl launch "$U" com.cognipin.previously -devSignInId "firstrun-$(date +%s)" -devSignInAuto 1 "$@"
